#!/usr/bin/perl
use v5.14;
use warnings;
use Authen::NTLM;
use HTTP::Tiny;
use HTTP::CookieJar;
use Data::Dumper;
use JSON;
use Clone qw/clone/;
use Carp;
use Term::ReadLine;
use Term::ReadKey;
local $Data::Dumper::Terse=1;
local $Data::Dumper::Indent=1;
local $Data::Dumper::Sortkeys=1;
local $Data::Dumper::Deepcopy=1;

if (@ARGV != 2 || $ARGV[0] ne '-c') {
    die "Usage: $0 -c <config file>";
}
if (!-f $ARGV[1]) {
    die "Cannot find config file $ARGV[1]";
}

my %config;
PARSE_CONFIG: {
    open my $fh, '<', $ARGV[1];
    my $config_body= join '', <$fh>;
    close $fh;
    my $line= 1;

    my $config_error= sub { push @_, " at $ARGV[1] line $line\n"; goto &Carp::croak; };

    my $get_lexeme= sub {
        my $optional= shift;
        my $lexeme= '';
        my $in_quote;

        while ($config_body =~ s!
            \A
            (?:
                (?<ws>[ \t]+)
            |
                (?<nl>\n)
            |
                (?<comment>\#.*)
            |
                (?<standalone>[;\[\]\{\}])
            |
                (?<dq>"(?<inner>(?:[^\\"]++|(?:\\.)++)*+)")
            |
                (?<bare>[A-Za-z0-9\\_/.-]+)
            )
        !!x) {
            if ($+{nl})         { $line++; next }
            if ($+{ws})         { next; }
            if ($+{comment})    { next; }
            if ($+{standalone}) { return $+{standalone} }
            if ($+{dq})         { my $inner= $+{inner}; s/\\t/\t/g, s/\\n/\n/g for $inner; return $inner }
            if ($+{bare})       { return $+{bare} };
        }
        if ($config_body) {
            $config_error->("Unexpected junk");
        } elsif (!$config_body and !$optional) {
            $config_error->("Unexpected EOF");
        }
    };

    my $get_string= $get_lexeme;

    my $get_object; $get_object= sub {
        my $lex= $get_lexeme->();
        if ($lex eq '[') {
            my @result;
            while (my $obj= $get_object->()) {
                last if $obj eq ']';
                push @result, $obj;
            }
            return \@result;
        } else {
            return $lex;
        }
    };

    my $get_single_argument= sub {
        my $result= $get_object->();
        my $semicolon= $get_lexeme->();
        if ($semicolon ne ';') {
            $config_error->("Expected semicolon, found $semicolon");
        }
        return $result;
    };

    my $get_expression= sub {
        my $type= $get_object->();
        my $negate= 0;
        if ($type eq 'not') {
            $negate= 1;
            $type= $get_object->();
        }
        my $arg= $get_object->();
        return { type => $type, 0 => $arg, negate => $negate };
    };

    my %action_argc= (
        delete => 0,
        move => 1,
        copy => 1,
        setread => 0,
        category => 1,
    );
    my $get_action= sub {
        my $type= $get_lexeme->();
        if (!exists $action_argc{$type}) {
            $config_error->("Unknown action type: $type");
        }
        my %action= (type => $type);
        $action{$_}= $get_object->() for 0..($action_argc{$type}-1);
        return \%action;
    };

    my $get_rules; $get_rules= sub {
        my ($parent_expr)= @_;
        my $expr= $get_expression->();
        my $bracket= $get_lexeme->(); $config_error->("Expected {") unless $bracket eq '{';

        my $merged_expr= $parent_expr ? [ $parent_expr, $expr ] : $expr;

        my @rules;
        while (1) {
            my $next= $get_lexeme->();
            if ($next eq '}') {
                last;
            } elsif ($next eq 'action' || $next eq 'last-action') {
                my $action= $get_action->();
                for my $norm_expr (normalize_expr($merged_expr)) {
                    push @rules, Rule->new2($norm_expr, $next, $action, \%config);
                }
                $config_error->("Expected semicolon") unless $get_lexeme->() eq ';';
            } elsif ($next eq 'match') {
                my $subrules= $get_rules->($merged_expr);
                push @rules, @$subrules;
            } else {
                $config_error->("Unexpected $next");
            }
        }
        return \@rules;
    };

    my $get_folder; $get_folder= sub {
        my $folder_name= $get_string->();
        my $folder= Folder->new($folder_name);
        $config_error->("Expected { after folder name") unless $get_lexeme->() eq '{';
        while (my $next= $get_lexeme->()) {
            if ($next eq '}') {
                last;
            } elsif ($next eq 'folder') {
                $folder->add($get_folder->());
            } else {
                $config_error->("Unexpected $next in folder block");
            }
        }
        return $folder;
    };

    $config{folder}= Folder->new('root');
    $config{categories}= {};
    my @all_rules;
    while (my $next= $get_lexeme->(1)) {
        if ($next eq 'user' || $next eq 'host') {
            if ($config{$next}) {
                $config_error->("Found multiple values for $next");
            }
            $config{$next}= $get_single_argument->();
        } elsif ($next eq 'match') {
            my $rules= $get_rules->();
            push @all_rules, @$rules;
        } elsif($next eq 'action' || $next eq 'last-action') {
            my $action= $get_action->();
            push @all_rules, Rule->new2([], $next, $action, \%config);
            $config_error->("Expected semicolon") unless $get_lexeme->() eq ';';
        } elsif ($next eq 'folder') {
            $config{folder}->add($get_folder->());
        } elsif ($next eq 'category') {
            my $category= $get_single_argument->();
            if (ref $category) { $config_error->("A category must be specified as a name"); }
            $config{categories}{$category}= 1;
        } else {
            $config_error->("Unexpected '$next'");
        }
    }

    sub normalize_expr {
        my $expr= shift;
        if (ref $expr eq 'ARRAY') { # Bunch of ANDed exprs
            my @r= ([]);
            for my $e (@$expr) {
                my @submat= normalize_expr($e);
                my @newr;
                for my $sub (@submat) {
                    my @oldr= @{clone \@r};
                    push @$_, @$sub for @oldr;
                    push @newr, @oldr;
                }
                @r= @newr;
            }
            return @r;
        } elsif (ref $expr eq 'HASH') { # Single expr
            return [$expr];
        } else { die; }
    }

    $config{rules}= \@all_rules;
}

sub prompt_password {
    my $prompt= shift;
    my $term= Term::ReadLine->new('exchange');
    my $out= $term->OUT || \*STDOUT;

    ReadMode('noecho');
    my $password= $term->readline($prompt);
    ReadMode('restore');
    print "\n";
    $password or die "No password entered, cannot continue";
    chomp $password;
    return $password;
}

my $password= prompt_password("Password for $config{user} on $config{host}: ");

my $ntlm= Authen::NTLM->new(
    host => $config{host},
    user => $config{user},
    password => $password,
    version => 2,
);

my $url= "https://$config{host}";
my $tiny= HTTP::Tiny->new(
    cookie_jar => HTTP::CookieJar->new,
);

sub request {
    my ($type, $page, $options)= @_;

    $options //= {};
    my $new_options= clone $options;

    if (ref $new_options->{content}) {
        $new_options->{content}= encode_json($new_options->{content});
        $new_options->{headers}{'Content-Type'}= 'application/json; charset=utf-8';
    }
    if ($new_options->{content} && !exists $new_options->{headers}{'Content-Length'}) {
        $new_options->{headers}{'Content-Length'}= length $new_options->{content};
    }
    my $response= $tiny->request($type, "$url$page", $new_options);
    if ($response->{status} && $response->{status} == 401) {
        my $wwwauth= $response->{headers}{'www-authenticate'};
        $wwwauth= [$wwwauth] unless ref $wwwauth;
        if (!grep { $_ =~ /NTLM/ } @$wwwauth) {
            return $response;
        }
        $new_options->{headers}{Authorization}= "NTLM ".$ntlm->challenge;
        $response= $tiny->request($type, "$url$page", $new_options);
        if (!$tiny->connected) {
            die "It appears that HTTP::Tiny is unable to re-use connections, NTLM authentication cannot work";
        }

        $wwwauth= $response->{headers}{'www-authenticate'};
        $wwwauth= [$wwwauth] unless ref $wwwauth;
        my ($c)= grep { $_ =~ /^NTLM/ } @$wwwauth;
        if (!$c) { return $response; }
        $c =~ s/^NTLM //;
        $new_options->{headers}{Authorization}= "NTLM ".$ntlm->challenge($c);
        $response= $tiny->request($type, "$url$page", $new_options);
    }

    return $response;
}

sub jr {
    my $response= request(@_);
    if ($response->{status} != 200) {
        say Dumper decode_json($response->{content});
        die "Failed request";
    }
    my $dec= (decode_json($response->{content})->{d} or die "No response from server: $response->{content}");
    if ($dec->{ErrorRecords} && @{$dec->{ErrorRecords}}) {
        die "Error from server: $response->{content}";
    }
    return $dec;
}

#{ # Auth check
#    my $front_page= request(GET => "/owa/");
#    if (!$front_page->{status} || $front_page->{status} != 200) {
#        die 'Unable to authenticate';
#    }
#}
#
#my ($canary)= map $_->{value}, grep { $_->{name} eq 'UserContext' } $tiny->{cookie_jar}->cookies_for($url);
#$canary or die "Unable to find OWA CSRF token. Try closing Outlook Web Access and waiting a few minutes";

say "Authenticating to $config{host}";
my $token= do {
    my $rule_page= request(GET => "/ecp/RulesEditor/InboxRules.slab");
    my ($t)= ($rule_page->{content} =~ m/"ecpCanary"\s+value="([^"]+)"/);
    $t;
};
if (!$token) {
    die "Unable to find CSRF token";
}
say "Success";

sub get_rule_state {
    say "Getting current rule information";
    my $rules= jr(
        POST => "/ecp/RulesEditor/InboxRules.svc/GetList?msExchEcpCanary=$token",
        {
            content => {
                sort => {
                    Direction => 0,
                    PropertyName => "Priority"
                },
                filter => {}
            }
        }
    )->{Output};

    if (!$rules) { die "Unable to find existing rules" }

    my @all_rules;
    for my $rule (@$rules) {
        my $ruledetail= jr(
            POST => "/ecp/RulesEditor/InboxRules.svc/GetObject?msExchEcpCanary=$token",
            {
                content => {
                    identity => {
                        RawIdentity => $rule->{Identity}{RawIdentity},
                    },
                    properties => {
                        ReturnObjectType => 1,
                    },
                },
            }
        )->{Output};
        if (@$ruledetail != 1) { die "Huh?"; }
        $ruledetail= $ruledetail->[0];
        push @all_rules, Rule->new($ruledetail);
    }

    return \@all_rules;
}

sub delete_rule {
    my $rule= shift;
    say "Deleting rule ".$rule->name;
    jr(
        POST => "/ecp/RulesEditor/InboxRules.svc/RemoveObjects?msExchEcpCanary=$token",
        { content => {
            identities => [ $rule->identity ],
            parameters => undef,
        } }
    );
}

sub create_rule {
    my $rule= shift;
    say "Creating rule ".$rule->name;
    jr(
        POST => "/ecp/RulesEditor/InboxRules.svc/NewObject?msExchEcpCanary=$token",
        { content => {
            properties => $rule->properties,
        } }
    );
}

sub fetch_folders {
    say "Fetching folder information";
    jr(
        POST => "/ecp/MailboxFolders.svc/GetList?msExchEcpCanary=$token",
        { content => {
            filter => { FolderPickerType => 0 },
            sort => undef,
        } }
    );
}

sub create_folder {
    my ($folder, $parent)= @_;
    say "Creating folder ".$folder->name.", parent of ".$parent->{Name};
    return jr(
        POST => "/ecp/MailboxFolders.svc/NewObject?msExchEcpCanary=$token",
        { content => {
            properties => {
                Name => $folder->name,
                Parent => ":$parent->{ID}",
            },
        } },
    )->{Output}[0];
}

sub ensure_folders {
    my ($expected, $actual)= @_;
    if (!$actual) { die "error"; }

    my %actual_children= map { lc($_->{Name}), $_ } @{$actual->{Children}};
    for my $e (values %{$expected->{children}}) {
        if (!$actual_children{lc($e->name)}) {
            my $new_folder= create_folder($e, $actual);
            $actual_children{lc($e->name)}= $new_folder;
        }
        $e->update_actual($actual_children{lc($e->name)});
        ensure_folders($e, $actual_children{lc($e->name)});
    }
}

sub check_categories {
    say "Checking categories...";
    my @categories= @{jr(
        POST => "/ecp/RulesEditor/MessageCategories.svc/GetList?msExchEcpCanary=$token",
        { content => {
            filter => undef,
            sort => undef,
        } }
    )->{Output}};
    my %categories= map { $_->{Value}, $_ } @categories;

    for my $category (keys %{$config{categories}}) {
        if (!$categories{$category}) {
            die "Category in config but not on server: $category";
        }
    }
}

sub main {
    ensure_folders($config{folder}, fetch_folders()->{Output}[0]);
    check_categories;

    my $rules= get_rule_state;
    for my $rule (@$rules) {
        delete_rule($rule);
    }
    for my $rule (reverse @{$config{rules}}) {
        create_rule($rule);
    }
}

package Rule;
use v5.18;
use warnings;

my @global_return= qw/__type Priority Supported Identity Enabled CaptionText/;

sub new {
    my ($class, $rule)= @_;
    my %globl;
    @globl{@global_return}= delete @$rule{@global_return};
    my %prop= %$rule;
    return bless {
        global => \%globl,
        properties => \%prop,
    }, $class;
}

sub identity {
    my $self= shift;
    if ($self->{global}{Identity}) {
        return { RawIdentity => $self->{global}{Identity}{RawIdentity} };
    }
    return undef;
}

sub properties {
    my $self= shift;
    my $properties= $self->{properties};
    for my $k (keys %$properties) {
        my $v= $properties->{$k};
        if (ref $v && ref $v eq 'Folder') {
            $properties->{$k}= { RawIdentity => $v->id, DisplayName => $v->name };
        }
    }
    return $properties;
}

sub true { JSON::true }
sub false { JSON::false }

sub name {
    my $self= shift;
    my $name= "";
    for my $prop (sort keys %{$self->{properties}}) {
        next if $prop eq 'Name';
        $name .= " $prop";
        my $val= $self->{properties}{$prop};
        if (ref $val && ref $val eq 'ARRAY') {
            $name .= "=(@$val)" =~ s/[^a-zA-Z0-9().@\/\- ]+//rgs;
        } elsif (ref $val && ref $val eq 'HASH') {
            $name .= "=".($val->{DisplayName} // "(unknown)");
        } elsif (ref $val && $val->can('name')) {
            $name .= "=".$val->name;
        } else {
            $name .= "=$val";
        }
    }
    substr($name, 0, 1, '');
    return $name;
}

my %condmapsimple; BEGIN { %condmapsimple= (
    header =>           [ "HeaderContainsWords",            "ExceptIfHeaderContainsWords" ],
    subject =>          [ "SubjectContainsWords",           "ExceptIfSubjectContainsWords" ],
    body =>             [ "BodyContainsWords",              "ExceptIfBodyContainsWords"],
    recipient =>        [ "RecipientAddressContainsWords",  "ExceptIfRecipientAddressContainsWords" ],
    from =>             [ "FromAddressContainsWords",       "ExceptIfFromAddressContainsWords" ],
    'subject-or-body' =>[ "SubjectOrBodyContainsWords",     "ExceptIfSubjectOrBodyContainsWords" ],
) };

sub new2 {
    my ($class, $condition, $last_or_not, $action, $config)= @_;

    my %properties;
    $properties{StopProcessingRules}= true if $last_or_not eq 'last-action';

    for my $cond (@$condition) {
        if (my $smpl= $condmapsimple{$cond->{type}}[$cond->{negate}]) {
            if ($properties{$smpl}) {
                die "Outlook cannot match on the same property twice; $smpl already specified\n",Data::Dumper::Dumper(\%properties);
            }
            $properties{$smpl}= (ref $cond->{0} ? $cond->{0} : [$cond->{0}]);
        } else {
            die "Huh? Don't understand type $cond->{type}";
        }
    }

    ACTION: {
        my $type= $action->{type};
        if ($type eq 'delete') {
            $properties{DeleteMessage}= true;
        } elsif ($type eq 'move') {
            my @foldername= split /\//, $action->{0};
            my $f= $config->{folder};
            $f= $f->get($_) for @foldername;
            if (!$f) {
                die "Undefined folder: $action->{0}";
            }
            $properties{MoveToFolder}= $f;
        } elsif ($type eq 'category') {
            if (!$config{categories}{$action->{0}}) {
                die "Undefined category: $action->{0}";
            }
            $properties{ApplyCategory}= {
                RawIdentity => $action->{0},
                DisplayName => $action->{0},
            };
        } elsif ($type eq 'setread') {
            $properties{MarkAsRead}= true;
        } else {
            die "Unknown action type: $type";
        }
    }

    my $self= bless {
        global => {},
        properties => \%properties,
    }, $class;
    $self->{properties}{Name}= $self->name;

    return $self;
}

package Folder;
use v5.14;
use warnings;

sub new {
    my ($class, $name)= @_;
    return bless { name => $name }, $class;
}

sub add {
    my ($self, $folder)= @_;
    if ($self->{children}{$folder->name}) {
        die "Duplicate folder definition for ".$folder->name;
    }
    $self->{children}{lc($folder->name)}= $folder;
}

sub get {
    my ($self, $name)= @_;
    return ($self->{children}{lc($name)} // undef);
}

sub name {
    $_[0]{name}
}

sub update_actual {
    my ($self, $actual)= @_;
    $self->{actual}= $actual;
}

sub id {
    $_[0]{actual}{ID} or die;
}

main::main;
