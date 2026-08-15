# Omi Web UI Design

This document defines the interface and implementation patterns shared by Omi's
FreePascal, JavaScript, and PHP web servers. New pages and controls should follow
these patterns so the three implementations remain familiar and interoperable.

The FreePascal server is currently maintained. JavaScript and PHP are paused;
these shared patterns apply when a paused implementation is compared or resumed,
but current changes are required only in FreePascal.

## Design goals

- Work without JavaScript, cookies, or client-side storage.
- Keep the generated interface usable in simple and retro browsers.
- Render the same navigation, terminology, and repository operations in every
  server implementation.
- Escape all dynamic HTML and translate all user-visible labels.
- Put repeated markup and path rules in language-local helper functions.

The servers are intentionally independent implementations. They cannot share a
runtime template, but each server should implement the same patterns once and
reuse its local helpers everywhere.

## Page structure

Pages use server-rendered HTML and a consistent order:

1. Omi title and logo.
2. Primary navigation as a compact row of controls.
3. On repository pages, a breadcrumb path made from signed buttons.
4. Page heading and status or error message.
5. Main content, normally a simple table or form.
6. Context-specific create or upload forms after the listing.

Repository breadcrumbs sit directly below the primary navigation without a
separate repository heading or `Path:` label. They begin with the `.omi` repository
name and continue with one button for each directory. Each button posts directly
to that clean path, so the browser URL shows the selected location. On a file page,
the final segment is plain text in `filename (type)` form because it identifies the
page already open:

`[wekan.omi] / [Directory] / [Subdirectory] / README.md (Markdown)`

Tables use descriptive column headings and `-` for a value or action that is not
available. Repository listings put the entry button in the first column and the
entry's operations in the Actions column.

## Buttons, links, and forms

Navigation and actions are buttons when a logged-in session must travel with the
request. This is part of the interface contract, not only visual styling.

- Public destinations may use ordinary links.
- Authenticated navigation uses a POST form whose `action` is the clean destination
  URL and whose hidden fields contain the session and signed one-time token.
- Session IDs and authentication tokens never appear in URLs. Addresses remain
  ordinary paths such as `/sign-in`, `/settings`, `/activity`, and `/repo/file`.
- Mutations always use POST and signed one-time authentication fields.
- Every independent action has its own form and token action name.
- Related actions are grouped on one row. Destructive actions are placed at the
  right side where the browser supports the layout.
- A destructive operation that removes a whole repository or a viewed file uses
  a confirmation step. Row operations may remain immediate when that is the
  established interface behavior.

Do not hand-build authentication fields at each call site. Use the server's
authentication-field helper and its navigation or signed-form helper.

Because Omi deliberately uses neither cookies nor URL sessions, a browser reload
cannot reuse the button session. A sessionless GET or a replayed/consumed POST on an
authenticated page redirects to the public home URL `/`. The user stays logged in
by clicking Omi buttons, which POST the hidden session to the next clean URL. Login
ends with a signed Continue button so the newly created session also enters the
interface without a URL token.

## Repository entries

Files and directories use the same row design:

- The name opens the entry through an authenticated navigation button.
- Rename is an inline text field and button.
- Delete is a separate button on the destructive side of the Actions column.
- Text files also have Edit before Rename.
- Mutation controls are shown only to logged-in users on the newest commit.
- Historical commit views are read-only.

Directory rename and delete apply to the marker and every descendant. File and
directory operations share rendering helpers, but keep separate storage helpers
because their commit semantics differ.

Every successful content change creates a commit. Rename creates a new snapshot
with rewritten paths. Delete creates a new snapshot without the selected entry;
earlier commits and their blobs remain available.

## Status, errors, and confirmation

- Success and error text appears near the operation that produced it.
- Errors should include the useful underlying cause when it is safe to display.
- Do not reduce an available diagnostic to only `Error`.
- Confirmation boxes identify the exact destructive target and contain Confirm
  and Cancel controls.
- Invalid, expired, or consumed page tokens return the browser to `/`, where the
  user can sign in again.

## Internationalization and escaping

- Retrieve labels through the translation helper instead of embedding English.
- HTML-escape translated values and all repository, file, directory, and user
  data when inserting them into markup.
- Use a hidden-input helper for hidden names and values so both are escaped in
  one place.
- Keep action identifiers stable and language-neutral; translate only labels.

## Shared helper responsibilities

Each server implementation should have one local helper for each repeated rule:

- HTML escaping.
- Translation lookup and escaped translation output.
- Hidden input rendering.
- Signed authentication fields.
- Signed inline POST forms.
- Authenticated navigation buttons.
- Navigation-row layout.
- Repository file/directory action layout.
- Joining normalized repository path segments.
- Full page shell and status/error rendering.

Before adding markup inline, check whether one of these helpers already owns the
pattern. Extend that helper when all its callers need the change. Add a specialized
helper when a repeated component has a stable contract. Do not combine operations
merely because their markup resembles each other when their validation or database
behavior differs.

## FreePascal helper map

The FreePascal server currently uses these common functions:

| Responsibility | Helper |
| --- | --- |
| Escape dynamic HTML | `HtmlEncode` |
| Translate labels | `T` and `TE` |
| Render hidden values | `BuildHiddenInput` |
| Add one-time authentication | `BuildAuthHiddenFields` |
| Render signed inline mutations | `BuildSignedInlineForm` |
| Render authenticated navigation | `BuildNavTargetButton` |
| Render compact navigation | `BuildNavRow` |
| Render file/directory actions | `BuildRepositoryEntryActions` |
| Join repository path segments | `JoinRepoPath` |

Use these functions instead of repeating their HTML or slash-handling rules in an
endpoint. Equivalent helpers should be added to the paused JavaScript and PHP
servers if maintenance of those implementations resumes.

## Review checklist

When adding or changing a web feature, verify that:

- it works without JavaScript and cookies;
- no generated URL contains a session ID or authentication token;
- authenticated buttons contain a distinct signed action token;
- mutations use POST and cannot appear in historical views;
- dynamic values and translated labels are escaped;
- the same component is not independently assembled in multiple call sites;
- repository changes create a commit and preserve older commits;
- errors explain the actionable cause;
- the maintained FreePascal interface follows this design; when another server is
  resumed, it adopts the same terminology and interaction pattern.
