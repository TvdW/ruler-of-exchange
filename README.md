# Ruler of Exchange

Sieve for Exchange but really just Perl doing HTTP requests

So the company I work for switched from a Linux-based mail stack to Microsoft's Exchange product... We used to have Sieve filters available, but that went away with the move, and Exchange only has its stupid rule editor.

So I wrote a quick replacement for Sieve: it's not nearly as powerful, but I managed to port my rules over without too much effort, other than writing this program. Maybe it helps someone else as well?

## Usage

    ./upload.pl -c <config file>

## Config format

### Example

    user "myusername";
    host "exchange.example.com";
    
    folder Inbox {
        # This will automatically create the folder if it does not exist
        folder Some-Mailing-List { }
    }
    
    # Must be created through the (web-)interface
    category "To me";
    
    match header "<some-mailing-list-id.lists.example.com>" {
        action setread;
        last-action move Inbox/Some-Mailing-List;
    }
    
    match recipient "first.lastname@company.com" {
        action category "To me";
    }

### Format

There are three allowed top-level settings, `user`, `host`, and `category`.

 - `user`: Specify the username to upload rules for. required
 - `host`: Specify the hostname to upload rules to. required
 - `category`: Define a category name that can later be used. Can be specified multiple times. Optional, but if you use categories, they must be declared prior to using them in a rule.

There are two block types, which are both allowed to recurse, `folder` and `match`.

`folder` specifies your folder structure. It is recommended to start with a definition for your inbox, and create your other folders in there. Folder blocks do not currently allow specifying any settings other than the name. When specifying folders in rules, their names are recursively joined using a `/` (forward slash).

    folder Inbox {
        folder MyFolder { } # Becomes "Inbox/MyFolder"
        folder AnotherFolder { } # Becomes "Inbox/AnotherFolder"
    }

`match` specifies your filter structure. After the `match` keyword, its expression follows (see the "Expressions" section), following with a bracket (`{`) indicating the start of its body. Within this body more `match` blocks may be created, applying an effective `AND` to your filters.

    match header "X-Spam: yes" {
        action delete;
    }

Within a `match` block actions may be specified. For information about these, see the "Actions" section.

A note on quoting: it is optional to quote strings that do not contain whitespace, semicolons (`;`), or brackets (`{`, `[`, `]`, `}`). If needed, escaping operations can be done using the usual backslash (`\`).

## Expressions

Six types of expressions are currently implemented, plus their negated versions (specified using a `not` after `match`).

    # Matches mails that contain "List-Id: " in their headers
    match header "List-Id: " { }
    # Matches mails that contain "Tom" or "Code" in the subject
    match subject ["Tom" "Code"] { }
    # Others:
    match body "some string" { }
    match recipient "my.mail@example.com" { 
    match not from "ceo@example.com" { } # Note the negation
    match subject-or-body [ "Hello World" "Just testing" ] { }

## Actions

Actions are indicated using the `action` and `last-action` keywords. In case of `last-action`, rule processing will stop after the action is executed.

Five actions are currently implemented :

 - `delete`: deletes the message
 - `move <folder>`: moves the message to a folder. The folder must be configured using a `folder` block
 - `copy <folder>`: same as move, but copies instead
 - `setread`: marks the message as read
 - `category <category>`: labels the message with a category. The category must be configured using a `category` option.

## Caveats

 - This software was implemented in a very short amount of time, bugs can happen
 - Rules are not being applied atomically; this means that while rules are being saved, some mails may get filtered in unexpected ways
 - Exchange supports a lot more types of rules and actions, I only implemented the most basic set I needed to satisfy what I need. Patches welcome
 - The config parser is dumb :-)

## License

This is free open-source software.
