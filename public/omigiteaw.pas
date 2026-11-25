{
  Omi - writing into a Gitea folder
  =================================

  Deleting one repository or a whole user or organization, and the list of
  repositories no longer synced from GitHub, straight in Gitea's SQLite
  database and folders - with Gitea STOPPED and only Omi running. Nothing here
  starts the Gitea server or its binary, or any other interpreter.

  Every write:

  - refuses while Gitea runs: a PID file that names a living process, a living
    `gitea web` for this app.ini (or this work directory), any process that
    has the database open (/proc/<pid>/fd), or anything answering on Gitea's
    HTTP_ADDR:HTTP_PORT;
  - takes the lock <APP_DATA_PATH>/.omi-gitea.lock (O_CREAT|O_EXCL, one line
    "<pid> <host> omi <UTC time>"; a lock of this host whose process is gone
    is stale and taken over once);
  - writes the database in ONE transaction (BEGIN IMMEDIATE ... COMMIT);
  - deletes files only after the commit. They are listed first in the synced
    journal <APP_DATA_PATH>/.omi-gitea.journal, which the next write finishes
    if this one was interrupted: each file is deleted only when no row refers
    to it any more, right whether the transaction committed or not.

  What a deletion removes follows Gitea's own DeleteRepositoryDirectly,
  deleteUser (purge) and deleteOrganization: GW_SETS (the ids, as TEMP tables),
  GW_DELETES (table and WHERE), GW_RECOUNT and GW_AFTER (other owners'
  counters), and GW_KEPT - the columns that point at an owner or a repository
  and are kept on purpose, with why. tests/gitea_test.py fails for a column of
  Gitea's schema in neither list.
}

unit omigiteaw;

{$MODE OBJFPC}
{$H+}

interface

uses
  {$IFDEF UNIX}
  BaseUnix, Unix, Sockets,
  {$ENDIF}
  SysUtils, Classes, Math, DateUtils, Process, fpjson, jsonparser, base64, RegExpr,
  fphttpclient,
  {$IFNDEF HASAMIGA}
  // TLS for https://. FreePascal has no TLS for the Amiga (no AmiSSL
  // binding): there only http:// addresses can be fetched.
  opensslsockets,
  {$ENDIF}
  omibackup, omigitea, omigit;

type
  EGw = class(Exception);
  TGwPair = record
    A, B: string;
  end;
  TGwTriple = record
    A, B, C: string;
  end;
  // A line of progress for a job's log.
  TGwSay = procedure(const Line: string) of object;

const
  GW_SETS: array[0..20] of TGwPair = (
    (A: 'd_repo'; B: 'SELECT id FROM repository WHERE owner_id = :uid'),
    (A: 'd_issue'; B: 'SELECT id FROM issue WHERE repo_id IN d_repo'),
    (A: 'd_pull'; B: 'SELECT id FROM pull_request WHERE base_repo_id IN d_repo OR issue_id IN d_issue'),
    (A: 'd_comment'; B: 'SELECT id FROM comment WHERE issue_id IN d_issue OR ref_repo_id IN d_repo OR ref_issue_id IN d_issue OR dependent_issue_id IN d_issue OR (:is_user AND poster_id = :uid AND type = 0)'),
    (A: 'd_release'; B: 'SELECT id FROM release WHERE repo_id IN d_repo'),
    (A: 'd_label'; B: 'SELECT id FROM label WHERE repo_id IN d_repo OR org_id = :uid'),
    (A: 'd_webhook'; B: 'SELECT id FROM webhook WHERE repo_id IN d_repo OR owner_id = :uid'),
    (A: 'd_project'; B: 'SELECT id FROM project WHERE repo_id IN d_repo OR owner_id = :uid'),
    (A: 'd_task'; B: 'SELECT id FROM action_task WHERE repo_id IN d_repo OR owner_id = :uid'),
    (A: 'd_run'; B: 'SELECT id FROM action_run WHERE repo_id IN d_repo OR owner_id = :uid'),
    (A: 'd_schedule'; B: 'SELECT id FROM action_schedule WHERE repo_id IN d_repo OR owner_id = :uid'),
    (A: 'd_runner'; B: 'SELECT id FROM action_runner WHERE repo_id IN d_repo OR owner_id = :uid'),
    (A: 'd_artifact'; B: 'SELECT id FROM action_artifact WHERE repo_id IN d_repo OR owner_id = :uid OR run_id IN d_run'),
    (A: 'd_package'; B: 'SELECT id FROM package WHERE owner_id = :uid'),
    (A: 'd_pversion'; B: 'SELECT id FROM package_version WHERE package_id IN d_package'),
    (A: 'd_pfile'; B: 'SELECT id FROM package_file WHERE version_id IN d_pversion'),
    (A: 'd_attachment'; B: 'SELECT id FROM attachment WHERE repo_id IN d_repo OR issue_id IN d_issue OR comment_id IN d_comment OR release_id IN d_release OR (uploader_id = :uid AND COALESCE(issue_id, 0) = 0 AND COALESCE(release_id, 0) = 0 AND COALESCE(comment_id, 0) = 0)'),
    (A: 'd_app'; B: 'SELECT id FROM oauth2_application WHERE uid = :uid'),
    (A: 'd_grant'; B: 'SELECT id FROM oauth2_grant WHERE user_id = :uid OR application_id IN d_app'),
    (A: 'd_gpgkey'; B: 'SELECT key_id FROM gpg_key WHERE owner_id = :uid'),
    (A: 'd_deploykey'; B: 'SELECT key_id FROM deploy_key WHERE repo_id IN d_repo')
  );
  GW_DELETES: array[0..100] of TGwPair = (
    (A: 'access'; B: 'repo_id IN d_repo OR user_id = :uid'),
    (A: 'access_token'; B: 'uid = :uid'),
    (A: 'action'; B: 'repo_id IN d_repo OR user_id = :uid OR act_user_id = :uid OR comment_id IN d_comment'),
    (A: 'action_artifact'; B: 'id IN d_artifact'),
    (A: 'action_run_attempt'; B: 'repo_id IN d_repo OR run_id IN d_run'),
    (A: 'action_run_index'; B: 'group_id IN d_repo'),
    (A: 'action_run_job'; B: 'repo_id IN d_repo OR owner_id = :uid OR run_id IN d_run'),
    (A: 'action_run_job_summary'; B: 'repo_id IN d_repo OR run_id IN d_run'),
    (A: 'action_run'; B: 'id IN d_run'),
    (A: 'action_runner'; B: 'id IN d_runner'),
    (A: 'action_runner_token'; B: 'repo_id IN d_repo OR owner_id = :uid'),
    (A: 'action_schedule_spec'; B: 'repo_id IN d_repo OR schedule_id IN d_schedule'),
    (A: 'action_schedule'; B: 'id IN d_schedule'),
    (A: 'action_scoped_workflow_source'; B: 'owner_id = :uid OR source_repo_id IN d_repo'),
    (A: 'action_task_output'; B: 'task_id IN d_task'),
    (A: 'action_task_step'; B: 'repo_id IN d_repo OR task_id IN d_task'),
    (A: 'action_task'; B: 'id IN d_task'),
    (A: 'action_tasks_version'; B: 'owner_id = :uid OR repo_id IN d_repo'),
    (A: 'action_variable'; B: 'owner_id = :uid OR repo_id IN d_repo'),
    (A: 'attachment'; B: 'id IN d_attachment'),
    (A: 'auth_token'; B: 'user_id = :uid'),
    (A: 'branch'; B: 'repo_id IN d_repo'),
    (A: 'collaboration'; B: 'repo_id IN d_repo OR user_id = :uid'),
    (A: 'comment'; B: 'id IN d_comment'),
    (A: 'commit_status'; B: 'repo_id IN d_repo'),
    (A: 'commit_status_index'; B: 'repo_id IN d_repo'),
    (A: 'commit_status_summary'; B: 'repo_id IN d_repo'),
    (A: 'deploy_key'; B: 'repo_id IN d_repo'),
    (A: 'email_address'; B: 'uid = :uid'),
    (A: 'external_login_user'; B: 'user_id = :uid'),
    (A: 'follow'; B: 'user_id = :uid OR follow_id = :uid'),
    (A: 'gpg_key_import'; B: 'key_id IN d_gpgkey'),
    (A: 'gpg_key'; B: 'owner_id = :uid'),
    (A: 'hook_task'; B: 'hook_id IN d_webhook'),
    (A: 'issue_assignees'; B: 'issue_id IN d_issue OR assignee_id = :uid'),
    (A: 'issue_content_history'; B: 'issue_id IN d_issue OR comment_id IN d_comment'),
    (A: 'issue_dependency'; B: 'issue_id IN d_issue OR dependency_id IN d_issue'),
    (A: 'issue_index'; B: 'group_id IN d_repo'),
    (A: 'issue_label'; B: 'issue_id IN d_issue OR label_id IN d_label'),
    (A: 'issue_pin'; B: 'repo_id IN d_repo OR issue_id IN d_issue'),
    (A: 'issue_user'; B: 'issue_id IN d_issue OR uid = :uid'),
    (A: 'issue_watch'; B: 'issue_id IN d_issue OR user_id = :uid'),
    (A: 'issue'; B: 'id IN d_issue'),
    (A: 'label'; B: 'id IN d_label'),
    (A: 'language_stat'; B: 'repo_id IN d_repo'),
    (A: 'lfs_lock'; B: 'repo_id IN d_repo OR owner_id = :uid'),
    (A: 'lfs_meta_object'; B: 'repository_id IN d_repo'),
    (A: 'milestone'; B: 'repo_id IN d_repo'),
    (A: 'mirror'; B: 'repo_id IN d_repo'),
    (A: 'notification'; B: 'repo_id IN d_repo OR user_id = :uid OR issue_id IN d_issue OR comment_id IN d_comment'),
    (A: 'oauth2_authorization_code'; B: 'grant_id IN d_grant'),
    (A: 'oauth2_grant'; B: 'id IN d_grant'),
    (A: 'oauth2_application'; B: 'id IN d_app'),
    (A: 'org_user'; B: 'org_id = :uid OR uid = :uid'),
    (A: 'package_property'; B: '(ref_type = 0 AND ref_id IN d_pversion) OR (ref_type = 1 AND ref_id IN d_pfile) OR (ref_type = 2 AND ref_id IN d_package)'),
    (A: 'package_file'; B: 'id IN d_pfile'),
    (A: 'package_version'; B: 'id IN d_pversion'),
    (A: 'package'; B: 'id IN d_package'),
    (A: 'package_cleanup_rule'; B: 'owner_id = :uid'),
    (A: 'project_issue'; B: 'project_id IN d_project OR issue_id IN d_issue'),
    (A: 'project_board'; B: 'project_id IN d_project'),
    (A: 'project_workflow'; B: 'project_id IN d_project'),
    (A: 'project'; B: 'id IN d_project'),
    (A: 'protected_branch'; B: 'repo_id IN d_repo'),
    (A: 'protected_tag'; B: 'repo_id IN d_repo'),
    (A: 'public_key'; B: 'owner_id = :uid OR (id IN d_deploykey AND id NOT IN (SELECT key_id FROM deploy_key))'),
    (A: 'pull_auto_merge'; B: 'pull_id IN d_pull OR doer_id = :uid'),
    (A: 'review_state'; B: 'pull_id IN d_pull OR user_id = :uid'),
    (A: 'pull_request'; B: 'id IN d_pull'),
    (A: 'push_mirror'; B: 'repo_id IN d_repo'),
    (A: 'reaction'; B: 'issue_id IN d_issue OR comment_id IN d_comment OR release_id IN d_release OR user_id = :uid'),
    (A: 'release'; B: 'id IN d_release'),
    (A: 'renamed_branch'; B: 'repo_id IN d_repo'),
    (A: 'repo_archiver'; B: 'repo_id IN d_repo'),
    (A: 'repo_indexer_status'; B: 'repo_id IN d_repo'),
    (A: 'repo_license'; B: 'repo_id IN d_repo'),
    (A: 'repo_redirect'; B: 'owner_id = :uid OR redirect_repo_id IN d_repo'),
    (A: 'repo_topic'; B: 'repo_id IN d_repo'),
    (A: 'repo_transfer'; B: 'repo_id IN d_repo OR doer_id = :uid OR recipient_id = :uid'),
    (A: 'repo_unit'; B: 'repo_id IN d_repo'),
    (A: 'review'; B: 'issue_id IN d_issue'),
    (A: 'secret'; B: 'owner_id = :uid OR repo_id IN d_repo'),
    (A: 'star'; B: 'repo_id IN d_repo OR uid = :uid'),
    (A: 'stopwatch'; B: 'issue_id IN d_issue OR user_id = :uid'),
    (A: 'task'; B: 'repo_id IN d_repo OR owner_id = :uid OR doer_id = :uid'),
    (A: 'team_invite'; B: 'org_id = :uid OR inviter_id = :uid'),
    (A: 'team_repo'; B: 'org_id = :uid OR repo_id IN d_repo'),
    (A: 'team_unit'; B: 'org_id = :uid'),
    (A: 'team_user'; B: 'org_id = :uid OR uid = :uid'),
    (A: 'team'; B: 'org_id = :uid'),
    (A: 'tracked_time'; B: 'issue_id IN d_issue'),
    (A: 'two_factor'; B: 'uid = :uid'),
    (A: 'user_badge'; B: 'user_id = :uid'),
    (A: 'user_blocking'; B: 'blocker_id = :uid OR blockee_id = :uid'),
    (A: 'user_redirect'; B: 'redirect_user_id = :uid'),
    (A: 'user_setting'; B: 'user_id = :uid'),
    (A: 'watch'; B: 'repo_id IN d_repo OR user_id = :uid'),
    (A: 'webauthn_credential'; B: 'user_id = :uid'),
    (A: 'webhook'; B: 'id IN d_webhook'),
    (A: 'repository'; B: 'id IN d_repo'),
    (A: 'user'; B: 'id = :uid')
  );
  GW_KEPT: array[0..26] of TGwPair = (
    (A: 'action_run.trigger_user_id'; B: 'a run in another owner''s repository keeps who started it (a ghost)'),
    (A: 'action_run.workflow_repo_id'; B: 'a run of another repository keeps where its workflow came from'),
    (A: 'action_run_attempt.trigger_user_id'; B: 'as action_run.trigger_user_id'),
    (A: 'action_run_job.workflow_source_repo_id'; B: 'a job of another repository keeps its workflow source'),
    (A: 'action_schedule.trigger_user_id'; B: 'a schedule of another repository keeps who made it'),
    (A: 'attachment.uploader_id'; B: 'a file the user uploaded to another owner''s issue stays with that issue'),
    (A: 'audit_event.actor_id'; B: 'the audit log keeps what was done, and by whom'),
    (A: 'branch.pusher_id'; B: 'a branch of another owner keeps who pushed it (a ghost)'),
    (A: 'branch.deleted_by_id'; B: 'as branch.pusher_id'),
    (A: 'comment.poster_id'; B: 'events (not text comments) in other owners'' issues stay, as Gitea keeps them'),
    (A: 'comment.assignee_id'; B: 'an assignment event in another owner''s issue stays'),
    (A: 'comment.resolve_doer_id'; B: 'a resolved review comment in another owner''s issue stays'),
    (A: 'commit_status.creator_id'; B: 'a commit status of another owner''s repository stays'),
    (A: 'issue.poster_id'; B: 'an issue in another owner''s repository stays, by a ghost, as in Gitea'),
    (A: 'issue_content_history.poster_id'; B: 'the edit history of another owner''s issue stays'),
    (A: 'issue_dependency.user_id'; B: 'a dependency between other owners'' issues stays'),
    (A: 'package_version.creator_id'; B: 'a package version of another owner stays'),
    (A: 'project.creator_id'; B: 'a project of another owner stays'),
    (A: 'project_board.creator_id'; B: 'a project column of another owner stays'),
    (A: 'pull_request.head_repo_id'; B: 'a pull request into another owner''s repository stays; Gitea shows its head as deleted'),
    (A: 'pull_request.merger_id'; B: 'a merged pull request of another owner keeps who merged it (a ghost)'),
    (A: 'release.publisher_id'; B: 'a release of another owner''s repository stays'),
    (A: 'repository.fork_id'; B: 'another owner''s fork becomes a repository of its own (UPDATE fork_id = 0)'),
    (A: 'repository.template_id'; B: 'another owner''s repository made from a template keeps its code (UPDATE template_id = 0)'),
    (A: 'review.reviewer_id'; B: 'a review in another owner''s pull request stays, as Gitea keeps it'),
    (A: 'tracked_time.user_id'; B: 'time tracked in another owner''s issue stays, as Gitea keeps it'),
    (A: 'package.repo_id'; B: 'another owner''s package linked to a deleted repository is unlinked (UPDATE repo_id = 0)')
  );
  GW_RECOUNT: array[0..10] of TGwTriple = (
    (A: 'r_starred_by_user'; B: 'SELECT repo_id FROM star WHERE uid = :uid AND repo_id NOT IN d_repo'; C: 'UPDATE repository SET num_stars = (SELECT COUNT(*) FROM star WHERE star.repo_id = repository.id) WHERE id IN r_starred_by_user'),
    (A: 'r_watched_by_user'; B: 'SELECT repo_id FROM watch WHERE user_id = :uid AND repo_id NOT IN d_repo'; C: 'UPDATE repository SET num_watches = (SELECT COUNT(*) FROM watch WHERE watch.repo_id = repository.id AND watch.mode <> 2) WHERE id IN r_watched_by_user'),
    (A: 'u_starring'; B: 'SELECT uid FROM star WHERE repo_id IN d_repo AND uid <> :uid'; C: 'UPDATE user SET num_stars = (SELECT COUNT(*) FROM star WHERE star.uid = user.id) WHERE id IN u_starring'),
    (A: 'u_follow'; B: 'SELECT follow_id FROM follow WHERE user_id = :uid UNION SELECT user_id FROM follow WHERE follow_id = :uid'; C: 'UPDATE user SET num_followers = (SELECT COUNT(*) FROM follow WHERE follow.follow_id = user.id), num_following = (SELECT COUNT(*) FROM follow WHERE follow.user_id = user.id) WHERE id IN u_follow'),
    (A: 'o_member'; B: 'SELECT org_id FROM org_user WHERE uid = :uid AND org_id <> :uid'; C: 'UPDATE user SET num_members = (SELECT COUNT(*) FROM org_user WHERE org_user.org_id = user.id) WHERE id IN o_member'),
    (A: 't_member'; B: 'SELECT team_id FROM team_user WHERE uid = :uid AND org_id <> :uid'; C: 'UPDATE team SET num_members = (SELECT COUNT(*) FROM team_user WHERE team_user.team_id = team.id) WHERE id IN t_member'),
    (A: 'i_commented'; B: 'SELECT issue_id FROM comment WHERE id IN d_comment AND issue_id NOT IN d_issue'; C: 'UPDATE issue SET num_comments = (SELECT COUNT(*) FROM comment WHERE comment.issue_id = issue.id AND comment.type IN (0, 22)) WHERE id IN i_commented'),
    (A: 'r_forked_from'; B: 'SELECT fork_id FROM repository WHERE id IN d_repo AND COALESCE(fork_id, 0) <> 0'; C: 'UPDATE repository SET num_forks = (SELECT COUNT(*) FROM repository f WHERE f.fork_id = repository.id) WHERE id IN r_forked_from'),
    (A: 'o_owner'; B: 'SELECT owner_id FROM repository WHERE id IN d_repo'; C: 'UPDATE user SET num_repos = (SELECT COUNT(*) FROM repository WHERE repository.owner_id = user.id) WHERE id IN o_owner'),
    (A: 't_team_repo'; B: 'SELECT team_id FROM team_repo WHERE repo_id IN d_repo'; C: 'UPDATE team SET num_repos = (SELECT COUNT(*) FROM team_repo WHERE team_repo.team_id = team.id) WHERE id IN t_team_repo'),
    (A: 't_topic'; B: 'SELECT topic_id FROM repo_topic WHERE repo_id IN d_repo'; C: 'UPDATE topic SET repo_count = (SELECT COUNT(*) FROM repo_topic WHERE repo_topic.topic_id = topic.id) WHERE id IN t_topic')
  );
  GW_AFTER: array[0..3] of string = (
    'DELETE FROM topic WHERE id IN t_topic AND repo_count = 0',
    'UPDATE repository SET fork_id = 0, is_fork = 0 WHERE fork_id IN d_repo',
    'UPDATE repository SET template_id = 0 WHERE template_id IN d_repo',
    'UPDATE package SET repo_id = 0 WHERE repo_id IN d_repo'
  );
  GW_REF_COLUMNS = ' act_user_id actor_id assignee_id base_repo_id blockee_id blocker_id creator_id deleted_by_id doer_id follow_id fork_id head_repo_id inviter_id issue_id merger_id org_id owner_id poster_id publisher_id pusher_id recipient_id redirect_repo_id redirect_user_id ref_repo_id repo_id repository_id resolve_doer_id reviewer_id source_repo_id template_id trigger_user_id uid uploader_id user_id workflow_repo_id workflow_source_repo_id ';

// Why Gitea (or something else using its database or port) runs; empty when stopped.
// The port Omi itself listens on (set by the server before it starts). Omi
// serves the same files Gitea did, and may serve them on Gitea's own
// HTTP_PORT: what answers there is then Omi, not a running Gitea, and Omi's own
// writes must not be refused because of it.
var
  GwOwnPort: Integer = 0;

function GwRunning(const P: TGtPaths; const PidFile: string): TStringList;
// What deleting Owner - or only its repository Repo, when Repo <> '' - removes:
// rows per table, files and bytes. Read-only.
function GwPlanDelete(const P: TGtPaths; const Owner, Repo: string): TJSONObject;
// The deletion. Confirm must be Owner, or Owner/Repo, typed exactly.
function GwDelete(const P: TGtPaths; const Owner, Repo, Confirm, PidFile, ExcludeFile, By,
  IndexPath: string; ExcludeFromSync: Boolean; Say: TGwSay): TJSONObject;

// Deletes every orphan of the size index (GtLoadReport's): the files nothing
// in the database uses, and the attachment and LFS rows whose file is gone.
// Confirm must be the number of orphans, typed. Each file is checked against
// the database again just before it goes (the journal's Referenced), so what
// Gitea uses is kept. Repository rows, package rows and size mismatches are
// kept too: deleting them is not safe here.
function GwDeleteOrphans(const P: TGtPaths; const Confirm, PidFile, IndexPath: string; Say: TGwSay): TJSONObject;

// The exclude file shared with github-to-gitea (github-to-gitea.exclude.txt):
// gitea_attachments.parse_exclude_file's rules - everything from '#' to the
// end of a line is a comment, entries one a line or comma separated.
function GwParseExcludes(const Text: string): TStringList;
function GwExcludeList(const Path: string): TStringList;
function GwExcludeCheck(const Full: string): Boolean;
procedure GwExcludeAdd(const Path, Full: string);
function GwExcludeRemove(const Path, Full: string): Boolean;
function GwIsExcluded(const Path, Full: string): Boolean;

function GwDeletedLogPath(const P: TGtPaths): string;

// Imports from GitHub into the stopped Gitea: Repos is empty (all) or names
// separated by spaces; Api/Web/GitRoot/FileHosts are GitHub's addresses (the
// tests give local ones). The token is read from TokenFile, never shown.
// GitProgram is the git program for the fetch when GitFetch is 'program'
// (GwFindGit's); GitFetch '' is the default.
function GwImportFull(const P: TGtPaths; const Owner, Repos, TokenFile, Api, Web, GitRoot, FileHosts, Doer,
  AppPath, ExcludeFile, PidFile, GitProgram, GitFetch: string; Say: TGwSay): TJSONObject;

// A running import stops when this file exists: checked before every GitHub
// request and while a rate limit is waited out, so a stop ends the job the way
// a failed request does (the open write rolled back, the journal finished).
// Per thread: each job sets its own. '' is never stopped.
threadvar
  GwStopFile: string;
  // RELEASE_ASSETS_KEEP: the files of how many of the newest releases an
  // import keeps - 'newest' (the default, 1), a number, or 'all'. Older
  // releases are imported without files, and their files in Gitea removed.
  GwReleaseAssetsKeep: string;

// "Test the token" (server.pas): GitHub's answer to GET /user with the token
// read from TokenFile. Result is 'none' (no token), 'ok', 'rejected' (401),
// 'refused' (another answer; Detail says which) or 'unreachable'. Login and
// the rate limit come from the answer; the token itself is never returned.
function GwTestGithubToken(const TokenFile, Api: string; out Login, Remaining, Limit, Detail: string): string;

// The git program: Given (GIT=) when set; else, on the Amiga, the first of
// C:git, C:amiga-git and C:am-git (Aminet's dev/misc/amiga-git and
// dev/misc/am-git); elsewhere git on the PATH. '' when there is none.
function GwFindGit(const Given: string): string;
// Its `--version` line; '' when it does not run.
function GwGitVersion(const Git: string): string;
// GIT_FETCH: 'program' runs the git program for the fetch (only for it);
// anything else is refused. '' is the default.
function GwGitFetchMode(const Value: string): string;

implementation

const
  SQLITE_OK = 0;
  SQLITE_ROW = 100;
  SQLITE_DONE = 101;
  SQLITE_OPEN_READONLY = $00000001;
  SQLITE_OPEN_READWRITE = $00000002;
  SQLITE_OPEN_URI = $00000040;
  LOCK_NAME = '.omi-gitea.lock';
  // A bound value that is SQL NULL.
  GW_NULL = #0'NULL'#0;
  JOURNAL_NAME = '.omi-gitea.journal';

function sqlite3_open_v2(FileName: PChar; var Db: Pointer; Flags: Integer;
  Vfs: PChar): Integer; cdecl; external name GT_C + 'sqlite3_open_v2';
function sqlite3_close(Db: Pointer): Integer; cdecl; external name GT_C + 'sqlite3_close';
function sqlite3_errmsg(Db: Pointer): PChar; cdecl; external name GT_C + 'sqlite3_errmsg';
function sqlite3_busy_timeout(Db: Pointer; Ms: Integer): Integer; cdecl; external name GT_C + 'sqlite3_busy_timeout';
function sqlite3_prepare_v2(Db: Pointer; Sql: PChar; NBytes: Integer;
  var Stmt: Pointer; Tail: PPChar): Integer; cdecl; external name GT_C + 'sqlite3_prepare_v2';
function sqlite3_bind_text(Stmt: Pointer; Index: Integer; Value: PChar;
  NBytes: Integer; Destructor_: Pointer): Integer; cdecl; external name GT_C + 'sqlite3_bind_text';
function sqlite3_step(Stmt: Pointer): Integer; cdecl; external name GT_C + 'sqlite3_step';
function sqlite3_column_count(Stmt: Pointer): Integer; cdecl; external name GT_C + 'sqlite3_column_count';
function sqlite3_column_text(Stmt: Pointer; Col: Integer): PChar; cdecl; external name GT_C + 'sqlite3_column_text';
function sqlite3_column_bytes(Stmt: Pointer; Col: Integer): Integer; cdecl; external name GT_C + 'sqlite3_column_bytes';
function sqlite3_finalize(Stmt: Pointer): Integer; cdecl; external name GT_C + 'sqlite3_finalize';
function sqlite3_changes(Db: Pointer): Integer; cdecl; external name GT_C + 'sqlite3_changes';
function sqlite3_bind_null(Stmt: Pointer; Index: Integer): Integer; cdecl; external name GT_C + 'sqlite3_bind_null';

{ --- small helpers ------------------------------------------------------------ }

// https:// is refused, with why, where FreePascal has no TLS (the Amiga).
procedure GwNeedTls(const Url: string);
begin
  {$IFDEF HASAMIGA}
  raise EGw.Create('cannot fetch ' + Url + ': FreePascal has no TLS on this platform, so https:// cannot be ' +
    'read here; give an http:// address (a mirror or a TLS proxy on another machine).');
  {$ENDIF}
end;

function ifthen_(C: Boolean; const A, B: string): string;
begin
  if C then
    Result := A
  else
    Result := B;
end;

function ifthen_i(C: Boolean; A, B: Int64): Int64;
begin
  if C then
    Result := A
  else
    Result := B;
end;

function UtcNow: string;
begin
  Result := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"', LocalTimeToUniversal(Now));
end;

function RealPath(const Path: string): string;
begin
  Result := GtRealPath(Path);
end;

function ReadSmallFile(const Path: string): string;
var
  F: TFileStream;
begin
  Result := '';
  try
    F := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
    try
      SetLength(Result, F.Size);
      if F.Size > 0 then
        F.ReadBuffer(Result[1], F.Size);
    finally
      F.Free;
    end;
  except
    Result := '';
  end;
end;

{$IFDEF UNIX}
// /proc files report a size of 0: read until the end.
function ReadProcFile(const Path: string): string;
var
  Fd: cint;
  Buf: array[0..4095] of Char;
  N: TSsize;
  Chunk: string;
begin
  Result := '';
  Fd := fpOpen(Path, O_RDONLY);
  if Fd < 0 then
    Exit;
  try
    repeat
      N := fpRead(Fd, Buf, SizeOf(Buf));
      if N > 0 then
        begin
          SetString(Chunk, PChar(@Buf[0]), N);
          Result := Result + Chunk;
        end;
    until (N <= 0) or (Length(Result) > 65536);
  finally
    fpClose(Fd);
  end;
end;
{$ENDIF}

procedure WriteSynced(const Path, Text: string);
begin
  if not GtWriteSynced(Path, Text) then
    raise EGw.Create('cannot write ' + Path);
end;

procedure SyncDir(const Dir: string);
begin
  GtSyncDir(Dir);
end;

// Written beside, synced, renamed over: never half a file.
procedure ReplaceFile(const Path, Text: string);
begin
  GtForceDirs(ExtractFileDir(Path));
  WriteSynced(Path + '.tmp', Text);
  if not GtRenameOver(Path + '.tmp', Path) then
    raise EGw.Create('cannot rename ' + Path + '.tmp');
  SyncDir(ExtractFileDir(Path));
end;

// A process that lives, or one this platform cannot check (assumed to live).
function PidAlive(Pid: Int64): Boolean;
var
  Known: Boolean;
begin
  Result := GtPidAlive(Pid, Known);
end;

function Inside(const Root, Path: string): Boolean;
var
  R, X: string;
begin
  R := RealPath(Root);
  X := ExpandFileName(Path);
  if DirectoryExists(ExtractFileDir(X)) then
    X := GtPath([RealPath(ExtractFileDir(X)), ExtractFileName(X)]);
  Result := (R <> '') and (X <> R) and GtUnder(R, X);
end;

procedure WalkSize(const Path: string; var Bytes, Files: Int64);
var
  Names: TStringList;
  I: Integer;
  Size: Int64;
begin
  case GtKind(Path, Size) of
    gkFile:
      begin
        Inc(Bytes, Size);
        Inc(Files);
      end;
    gkLink:
      Inc(Files);
    gkDir:
      begin
        Names := GtListDir(Path);
        try
          for I := 0 to Names.Count - 1 do
            WalkSize(GtPath([Path, Names[I]]), Bytes, Files);
        finally
          Names.Free;
        end;
      end;
  end;
end;

function PathBytes(const Path: string): Int64;
var
  F: Int64;
begin
  Result := 0;
  F := 0;
  WalkSize(Path, Result, F);
end;

function PathFiles(const Path: string): Int64;
var
  B: Int64;
begin
  B := 0;
  Result := 0;
  WalkSize(Path, B, Result);
end;

procedure RemoveTree(const Path: string; var Files: Int64);
var
  Names: TStringList;
  I: Integer;
  Size: Int64;
  Kind: TGtKind;
begin
  Kind := GtKind(Path, Size);
  if Kind = gkNone then
    Exit;
  if Kind = gkDir then
  begin
    Names := GtListDir(Path);
    try
      for I := 0 to Names.Count - 1 do
        RemoveTree(GtPath([Path, Names[I]]), Files);
    finally
      Names.Free;
    end;
    RemoveDir(Path);
  end
  else if DeleteFile(Path) then
    Inc(Files);
end;

function Roots(const P: TGtPaths): TStringArray;
begin
  Result := nil;
  SetLength(Result, 9);
  Result[0] := P.RepoRoot;
  Result[1] := P.Attachments;
  Result[2] := P.Lfs;
  Result[3] := P.Packages;
  Result[4] := P.Avatars;
  Result[5] := P.RepoAvatars;
  Result[6] := P.ActionsLog;
  Result[7] := P.ActionsArtifacts;
  Result[8] := P.RepoArchive;
end;

// Removes a file or a tree of the Gitea folder, never anything outside its folders.
function RemovePath(const P: TGtPaths; const Path: string): Int64;
var
  R: TStringArray;
  I: Integer;
  Ok: Boolean;
begin
  Result := 0;
  R := Roots(P);
  Ok := False;
  for I := 0 to High(R) do
    if Inside(R[I], Path) then
      Ok := True;
  if not Ok then
    raise EGw.Create('refusing to remove ' + Path + ': not inside the Gitea folders');
  RemoveTree(Path, Result);
end;

function IsHexText(const S: string): Boolean;
var
  I: Integer;
begin
  Result := S <> '';
  for I := 1 to Length(S) do
    if not (S[I] in ['0'..'9', 'a'..'f']) then
      Exit(False);
end;

function NoDotDot(const S: string): Boolean;
begin
  Result := (S <> '') and (S[1] <> '/') and (Pos('/../', '/' + S + '/') = 0);
end;

{ --- SQLite, read-write ------------------------------------------------------ }

type
  TGwDb = class
  public
    Db: Pointer;
    constructor Open(const Path: string; ReadOnly: Boolean);
    destructor Destroy; override;
    procedure Exec(const Sql: string; const Params: array of string);
    function Changes(const Sql: string; const Params: array of string): Int64;
    function Query(const Sql: string; const Params: array of string): TGtRows;
    function Scalar(const Sql: string; const Params: array of string): string;
    function Has(const Sql: string; const Params: array of string): Boolean;
    function Tables: TStringList;
  end;

function UriOf(const Path, Mode: string): string;
var
  I: Integer;
begin
  Result := 'file:';
  for I := 1 to Length(Path) do
    case Path[I] of
      '%', '?', '#': Result := Result + '%' + IntToHex(Ord(Path[I]), 2);
    else
      Result := Result + Path[I];
    end;
  Result := Result + '?mode=' + Mode;
end;

constructor TGwDb.Open(const Path: string; ReadOnly: Boolean);
var
  Flags: Integer;
begin
  inherited Create;
  Db := nil;
  if not FileExists(Path) then
    raise EGw.Create('no such database: ' + Path);
  if ReadOnly then
    Flags := SQLITE_OPEN_READONLY or SQLITE_OPEN_URI
  else
    Flags := SQLITE_OPEN_READWRITE or SQLITE_OPEN_URI;
  if sqlite3_open_v2(PChar(UriOf(Path, ifthen_(ReadOnly, 'ro', 'rw'))), Db, Flags, nil) <> SQLITE_OK then
  begin
    if Assigned(Db) then
    begin
      sqlite3_close(Db);
      Db := nil;
    end;
    raise EGw.Create('SQLite could not open ' + Path);
  end;
  sqlite3_busy_timeout(Db, 5000);
  {$IFNDEF UNIX}
  // No shared memory for WAL's index here (the Amiga): SQLite documents that a
  // WAL database works without it in EXCLUSIVE locking mode. The journal mode
  // itself is not changed, so Gitea gets its WAL database back.
  Exec('PRAGMA locking_mode=EXCLUSIVE', []);
  {$ENDIF}
end;

destructor TGwDb.Destroy;
begin
  if Assigned(Db) then
    sqlite3_close(Db);
  inherited Destroy;
end;

function Prepare(Db: Pointer; const Sql: string; const Params: array of string): Pointer;
var
  I: Integer;
begin
  Result := nil;
  if sqlite3_prepare_v2(Db, PChar(Sql), -1, Result, nil) <> SQLITE_OK then
    raise EGw.Create(StrPas(sqlite3_errmsg(Db)) + ' in: ' + Copy(Sql, 1, 200));
  for I := 0 to High(Params) do
    if Params[I] = GW_NULL then
      sqlite3_bind_null(Result, I + 1)
    else if sqlite3_bind_text(Result, I + 1, PChar(Params[I]), Length(Params[I]), Pointer(-1)) <> SQLITE_OK then
    begin
      sqlite3_finalize(Result);
      raise EGw.Create(StrPas(sqlite3_errmsg(Db)));
    end;
end;

procedure TGwDb.Exec(const Sql: string; const Params: array of string);
begin
  Changes(Sql, Params);
end;

function TGwDb.Changes(const Sql: string; const Params: array of string): Int64;
var
  Stmt: Pointer;
  Rc: Integer;
begin
  Stmt := Prepare(Db, Sql, Params);
  try
    repeat
      Rc := sqlite3_step(Stmt);
    until Rc <> SQLITE_ROW;
    if Rc <> SQLITE_DONE then
      raise EGw.Create(StrPas(sqlite3_errmsg(Db)) + ' in: ' + Copy(Sql, 1, 200));
    Result := sqlite3_changes(Db);
  finally
    sqlite3_finalize(Stmt);
  end;
end;

function TGwDb.Query(const Sql: string; const Params: array of string): TGtRows;
var
  Stmt: Pointer;
  Rc, Cols, I, N, Count: Integer;
  PV: PChar;
  Row: TGtRow;
  V: string;
begin
  Result := nil;
  Stmt := Prepare(Db, Sql, Params);
  try
    Cols := sqlite3_column_count(Stmt);
    Count := 0;
    SetLength(Result, 16);
    repeat
      Rc := sqlite3_step(Stmt);
      if Rc = SQLITE_ROW then
      begin
        Row := nil;
        SetLength(Row, Cols);
        for I := 0 to Cols - 1 do
        begin
          PV := sqlite3_column_text(Stmt, I);
          N := sqlite3_column_bytes(Stmt, I);
          V := '';
          if Assigned(PV) and (N > 0) then
            SetString(V, PV, N);
          Row[I] := V;
        end;
        if Count = Length(Result) then
          SetLength(Result, Count * 2);
        Result[Count] := Row;
        Inc(Count);
      end;
    until Rc <> SQLITE_ROW;
    SetLength(Result, Count);
    if Rc <> SQLITE_DONE then
      raise EGw.Create(StrPas(sqlite3_errmsg(Db)) + ' in: ' + Copy(Sql, 1, 200));
  finally
    sqlite3_finalize(Stmt);
  end;
end;

function TGwDb.Scalar(const Sql: string; const Params: array of string): string;
var
  Rows: TGtRows;
begin
  Rows := Query(Sql, Params);
  if (Length(Rows) > 0) and (Length(Rows[0]) > 0) then
    Result := Rows[0][0]
  else
    Result := '';
end;

function TGwDb.Has(const Sql: string; const Params: array of string): Boolean;
begin
  Result := Length(Query(Sql, Params)) > 0;
end;

function TGwDb.Tables: TStringList;
var
  Rows: TGtRows;
  I: Integer;
begin
  Result := TStringList.Create;
  Result.Sorted := True;
  Rows := Query('SELECT name FROM sqlite_master WHERE type = ''table''', []);
  for I := 0 to High(Rows) do
    Result.Add(Rows[I][0]);
end;

{ --- is Gitea running? ----------------------------------------------------- }

function GwRunning(const P: TGtPaths; const PidFile: string): TStringList;
var
  Candidates: TStringArray;
  I: Integer;
  Pid: Int64;
  Known: Boolean;
  {$IFDEF UNIX}
  K: Integer;
  Sr, Fr: TSearchRec;
  Argv: TStringArray;
  Cmd, Cwd, Conf, DbReal, ConfReal, Link, Me: string;
  Sock: LongInt;
  Addr: TInetSockAddr;
  Web, Matched: Boolean;
  {$ENDIF}
begin
  Result := TStringList.Create;
  if PidFile <> '' then
    Candidates := [PidFile]
  else
    {$IFDEF UNIX}
    Candidates := ['/run/gitea.pid', '/var/run/gitea.pid', GtPath([P.WorkPath, 'gitea.pid'])];
    {$ELSE}
    Candidates := [GtPath([P.WorkPath, 'gitea.pid'])];
    {$ENDIF}
  for I := 0 to High(Candidates) do
    if FileExists(Candidates[I]) then
    begin
      Pid := StrToInt64Def(Trim(ReadSmallFile(Candidates[I])), 0);
      if GtPidAlive(Pid, Known) then
        if Known then
          Result.Add('the PID file ' + Candidates[I] + ' names process ' + IntToStr(Pid) + ', which is running')
        else
          // Gitea removes its PID file when it stops; here nothing tells
          // whether that process lives.
          Result.Add('the PID file ' + Candidates[I] + ' is there (process ' + IntToStr(Pid) +
            '); this system cannot tell whether it runs: delete the file if Gitea is stopped');
    end;
  {$IFDEF UNIX}
  DbReal := RealPath(P.DbPath);
  ConfReal := RealPath(P.AppIni);
  Me := IntToStr(GtPid);
  if FindFirst('/proc/*', faDirectory, Sr) = 0 then
  begin
    repeat
      if (Sr.Name = Me) or (StrToInt64Def(Sr.Name, -1) < 0) then
        Continue;
      Cmd := ReadProcFile('/proc/' + Sr.Name + '/cmdline'); // Linux's /proc: names, not paths of the Gitea folder
      if Cmd = '' then
        Continue;
      if Cmd[Length(Cmd)] = #0 then
        SetLength(Cmd, Length(Cmd) - 1);
      Argv := Cmd.Split([#0]);
      Matched := False;
      if (Length(Argv) > 0) and (Copy(ExtractFileName(Argv[0]), 1, 5) = 'gitea') then
      begin
        Web := False;
        Conf := '';
        for K := 0 to High(Argv) do
        begin
          if Argv[K] = 'web' then
            Web := True;
          if ((Argv[K] = '--config') or (Argv[K] = '-c')) and (K < High(Argv)) then
            Conf := Argv[K + 1]
          else if Copy(Argv[K], 1, 9) = '--config=' then
            Conf := Copy(Argv[K], 10, MaxInt);
        end;
        if Web then
        begin
          Cwd := fpReadLink('/proc/' + Sr.Name + '/cwd');
          if (Conf <> '') and (Conf[1] <> '/') and (Cwd <> '') then
            Conf := GtPath([Cwd, Conf]);
          if ((Conf <> '') and (RealPath(Conf) = ConfReal)) or
            ((Conf = '') and (Cwd <> '') and (RealPath(Cwd) = RealPath(P.WorkPath))) then
          begin
            Result.Add('process ' + Sr.Name + ' is `gitea web` for this app.ini');
            Matched := True;
          end;
        end;
      end;
      if Matched then
        Continue;
      if FindFirst('/proc/' + Sr.Name + '/fd/*', faAnyFile, Fr) = 0 then
      begin
        repeat
          Link := fpReadLink('/proc/' + Sr.Name + '/fd/' + Fr.Name);
          if (Link <> '') and (Link = DbReal) then
          begin
            Result.Add('process ' + Sr.Name + ' (' + ExtractFileName(Argv[0]) + ') has the database open');
            Break;
          end;
        until FindNext(Fr) <> 0;
        FindClose(Fr);
      end;
    until FindNext(Sr) <> 0;
    FindClose(Sr);
  end;
  if (P.HttpPort > 0) and (P.HttpPort <> GwOwnPort) then
  begin
    Sock := fpSocket(AF_INET, SOCK_STREAM, 0);
    if Sock >= 0 then
    try
      FillChar(Addr, SizeOf(Addr), 0);
      Addr.sin_family := AF_INET;
      Addr.sin_port := htons(P.HttpPort);
      Addr.sin_addr := StrToNetAddr(P.HttpAddr);
      if (Addr.sin_addr.s_addr <> 0) and (fpConnect(Sock, @Addr, SizeOf(Addr)) = 0) then
        Result.Add('something answers on Gitea''s HTTP port ' + P.HttpAddr + ':' + IntToStr(P.HttpPort));
    finally
      CloseSocket(Sock);
    end;
  end;
{$ENDIF}
end;

{ --- the lock and the journal ------------------------------------------------- }

type
  TGwWriter = class
  public
    P: TGtPaths;
    LockPath, JournalPath, Content: string;
    Say: TGwSay;
    // Progress of a delete's file removal: "progress <done>/<total> <step>"
    // lines in the job log (GwProgress), read by the job page's progress bar,
    // and "status removed <files> <bytes>" for its table.
    ProgressDone, ProgressTotal, ProgressBytes: Int64;
    constructor Enter(const AP: TGtPaths; const PidFile: string; ASay: TGwSay);
    destructor Destroy; override;
    procedure WriteJournal(const Op: string; Entries: TJSONArray);
    function FinishJournal: Int64;
  end;

function Referenced(Db: TGwDb; const Kind, Key: string): Boolean;
var
  Sql: string;
begin
  // Gitea writes a uuid in lower case; `lower(uuid) = ...` read the whole
  // attachment table for every file, which on a Gitea with years of release
  // files made removing them take hours. An equality uses the uuid index.
  if Kind = 'attachment' then
    Sql := 'SELECT 1 FROM attachment WHERE uuid = lower(?1) OR uuid = ?1'
  else if Kind = 'lfs' then
    Sql := 'SELECT 1 FROM lfs_meta_object WHERE oid = ?1'
  else if Kind = 'package' then
    Sql := 'SELECT 1 FROM package_blob WHERE hash_sha256 = ?1'
  else if Kind = 'avatar' then
    Sql := 'SELECT 1 FROM user WHERE avatar = ?1 UNION SELECT 1 FROM repository WHERE avatar = ?1'
  else if Kind = 'owner' then
    Sql := 'SELECT 1 FROM user WHERE lower_name = ?1 UNION SELECT 1 FROM repository WHERE lower(owner_name) = ?1'
  else if Kind = 'repo' then
    Sql := 'SELECT 1 FROM repository WHERE lower(owner_name) || ''/'' || lower_name = ?1'
  else if Kind = 'actions_log' then
    Sql := 'SELECT 1 FROM action_task WHERE log_filename = ?1'
  else if Kind = 'artifact' then
    Sql := 'SELECT 1 FROM action_artifact WHERE storage_path = ?1'
  else if Kind = 'archive' then
    Sql := 'SELECT 1 FROM repository WHERE CAST(id AS TEXT) = ?1'
  else
    // An unknown kind is kept: never delete what cannot be checked.
    Exit(True);
  Result := Db.Has(Sql, [Key]);
end;

constructor TGwWriter.Enter(const AP: TGtPaths; const PidFile: string; ASay: TGwSay);
var
  Running: TStringList;
  Known: Boolean;
  Held, Busy: string;
  Parts: TStringArray;
  Attempt: Integer;
  Probe: TGwDb;
begin
  inherited Create;
  Busy := '';
  P := AP;
  Say := ASay;
  Content := '';
  LockPath := GtPath([P.AppDataPath, LOCK_NAME]);
  JournalPath := GtPath([P.AppDataPath, JOURNAL_NAME]);
  if P.DbType <> 'sqlite3' then
    raise EGw.Create('Omi writes only a Gitea that uses SQLite; this one uses ' + P.DbType + '.');
  if P.NonLocal <> '' then
    raise EGw.Create('Some storages are not on the local disk: ' + P.NonLocal);
  Running := GwRunning(P, PidFile);
  try
    if Running.Count > 0 then
      raise EGw.Create('Gitea is running; stop it first. ' + StringReplace(Trim(Running.Text), LineEnding, '; ',
        [rfReplaceAll]));
  finally
    Running.Free;
  end;
  for Attempt := 1 to 2 do
  begin
    Content := IntToStr(GtPid) + ' ' + GtHostName + ' omi ' + UtcNow + #10;
    if GtCreateExclusive(LockPath, Content) then
      Break;
    Content := '';
    Held := Trim(ReadSmallFile(LockPath));
    Parts := Held.Split([' ']);
    // A lock of this host whose process is gone is stale - where the platform
    // can tell; elsewhere it stays until it is deleted by hand.
    if (Attempt = 1) and (Length(Parts) >= 2) and (Parts[1] = GtHostName) and
      (StrToInt64Def(Parts[0], 0) > 0) and not GtPidAlive(StrToInt64Def(Parts[0], 0), Known) and Known then
    begin
      DeleteFile(LockPath);
      Continue;
    end;
    raise EGw.Create('The Gitea folder is being changed by another program: ' + Held +
      ifthen_(Known, '', ' (if no Omi runs, delete ' + LockPath + ')'));
  end;
  // A database another program holds locked (SQLITE_BUSY) is refused on every
  // platform, also where nothing else can tell whether Gitea runs.
  Probe := TGwDb.Open(P.DbPath, False);
  try
    sqlite3_busy_timeout(Probe.Db, 0);
    try
      Probe.Exec('BEGIN IMMEDIATE', []);
      Probe.Exec('ROLLBACK', []);
    except
      on E: EGw do
      begin
        Busy := E.Message;
      end;
    end;
  finally
    Probe.Free;
  end;
  if Busy <> '' then
  begin
    if (Content <> '') and (ReadSmallFile(LockPath) = Content) then
      DeleteFile(LockPath);
    Content := '';
    raise EGw.Create('The Gitea database is in use by another program (' + Busy + ').');
  end;
  try
    if FileExists(JournalPath) and Assigned(Say) then
      Say('Finished a write that was interrupted: ' + IntToStr(FinishJournal) + ' files removed.');
  except
    Destroy;
    raise;
  end;
end;

destructor TGwWriter.Destroy;
begin
  if (Content <> '') and (ReadSmallFile(LockPath) = Content) then
    DeleteFile(LockPath);
  inherited Destroy;
end;

procedure TGwWriter.WriteJournal(const Op: string; Entries: TJSONArray);
var
  J: TJSONObject;
begin
  J := TJSONObject.Create(['op', Op, 'time', UtcNow]);
  try
    J.Add('entries', Entries.Clone);
    ReplaceFile(JournalPath, J.AsJSON);
  finally
    J.Free;
  end;
end;

// One progress line of a job's log: "progress <done>/<total> <step>". The job
// page (server.pas ShowJob) shows the newest as a bar and a percentage.
// The size of a file, 0 when it is not there (or is a folder).
function GwFileSize(const Path: string): Int64;
var
  Sr: TSearchRec;
begin
  Result := 0;
  if (Path <> '') and (FindFirst(Path, faAnyFile, Sr) = 0) then
  begin
    if (Sr.Attr and faDirectory) = 0 then
      Result := Sr.Size;
    FindClose(Sr);
  end;
end;

// A line the job page keeps the newest of per key, for its table of the whole
// job: "status <key> <value>". The keys: started (Unix time), repos
// (<n>/<total>), repo, phase (a translation key: issues, comments,
// pull-requests, releases, space-freed, attachments, save; or git), toremove,
// removed and fetched (<files> <bytes>).
procedure GwStatus(Say: TGwSay; const Key, Value: string);
begin
  if Assigned(Say) then
    Say('status ' + Key + ' ' + Value);
end;

procedure GwProgress(Say: TGwSay; Done, Total: Int64; const Step: string);
begin
  if Assigned(Say) and (Total > 0) then
    Say('progress ' + IntToStr(Done) + '/' + IntToStr(Total) + ' ' + Step);
end;

function TGwWriter.FinishJournal: Int64;
var
  J: TJSONData;
  E: TJSONArray;
  I: Integer;
  Db: TGwDb;
  O: TJSONObject;
begin
  Result := 0;
  if not FileExists(JournalPath) then
    Exit;
  J := GetJSON(ReadSmallFile(JournalPath));
  Db := TGwDb.Open(P.DbPath, True);
  try
    if (J is TJSONObject) and (TJSONObject(J).Find('entries') is TJSONArray) then
    begin
      E := TJSONArray(TJSONObject(J).Find('entries'));
      for I := 0 to E.Count - 1 do
        if E.Items[I] is TJSONObject then
        begin
          O := TJSONObject(E.Items[I]);
          if not Referenced(Db, O.Get('kind', ''), O.Get('key', '')) then
          begin
            if ProgressTotal > 0 then
              Inc(ProgressBytes, GwFileSize(O.Get('path', '')));
            Inc(Result, RemovePath(P, O.Get('path', '')));
          end;
          if ProgressTotal > 0 then
          begin
            Inc(ProgressDone);
            if (ProgressTotal <= 200) or (ProgressDone = ProgressTotal) or
              (ProgressDone mod Max(1, ProgressTotal div 100) = 0) then
              GwStatus(Say, 'removed', IntToStr(ProgressDone) + ' ' + IntToStr(ProgressBytes));
            // Every file of a few hundred; of tens of thousands about every
            // per cent, or the log is a line per file.
            if (ProgressTotal <= 200) or (ProgressDone = ProgressTotal) or
              (ProgressDone mod Max(1, ProgressTotal div 100) = 0) then
              GwProgress(Say, ProgressDone, ProgressTotal, 'files: ' + O.Get('kind', '') + ' ' + O.Get('path', ''));
          end;
        end;
    end;
  finally
    Db.Free;
    J.Free;
  end;
  DeleteFile(JournalPath);
  SyncDir(P.AppDataPath);
end;

{ --- deleting ------------------------------------------------------------------- }

type
  TGwOwner = record
    Id, Name, Kind, Avatar: string;
    IsAdmin: Boolean;
  end;

function FindOwner(Db: TGwDb; const Name: string): TGwOwner;
var
  Rows: TGtRows;
begin
  if not GtNameIsSafe(Name) then
    raise EGw.Create('not a Gitea owner name: ''' + Name + '''');
  Rows := Db.Query('SELECT id, name, COALESCE(type, 0), COALESCE(avatar, ''''), COALESCE(is_admin, 0) FROM user ' +
    'WHERE lower_name = ?1 AND COALESCE(type, 0) IN (0, 1)', [LowerCase(Name)]);
  if Length(Rows) = 0 then
    raise EGw.Create('no user or organization ' + Name + ' in Gitea');
  Result.Id := Rows[0][0];
  Result.Name := Rows[0][1];
  if Rows[0][2] = '1' then
    Result.Kind := 'organization'
  else
    Result.Kind := 'user';
  Result.Avatar := Rows[0][3];
  Result.IsAdmin := Rows[0][4] = '1';
end;

// :uid, :rid and :is_user are always integers: put into the SQL text.
function Bind(const Sql, Uid, Rid, IsUser: string): string;
begin
  Result := StringReplace(Sql, ':uid', Uid, [rfReplaceAll]);
  Result := StringReplace(Result, ':rid', Rid, [rfReplaceAll]);
  Result := StringReplace(Result, ':is_user', IsUser, [rfReplaceAll]);
end;

function SourceTable(const Sql: string): string;
var
  S: string;
  I: Integer;
begin
  S := Copy(Sql, Pos(' FROM ', Sql) + 6, MaxInt);
  I := Pos(' ', S);
  if I > 0 then
    S := Copy(S, 1, I - 1);
  Result := S;
end;

procedure MakeSets(Db: TGwDb; Tables: TStringList; const Uid, Rid, IsUser: string; RepoOnly: Boolean);
var
  I: Integer;
  Name, Sql: string;

  procedure One(const AName, ASql: string);
  begin
    Db.Exec('DROP TABLE IF EXISTS temp.' + AName, []);
    if Tables.IndexOf(SourceTable(ASql)) < 0 then
      Db.Exec('CREATE TEMP TABLE ' + AName + ' (id INTEGER PRIMARY KEY)', [])
    else
      Db.Exec('CREATE TEMP TABLE ' + AName + ' AS ' + Bind(ASql, Uid, Rid, IsUser), []);
  end;

begin
  for I := 0 to High(GW_SETS) do
  begin
    Name := GW_SETS[I].A;
    Sql := GW_SETS[I].B;
    // One repository: DeleteRepositoryDirectly. :uid is -1, so no row of the
    // owner itself matches.
    if RepoOnly and (Name = 'd_repo') then
      Sql := 'SELECT id FROM repository WHERE id = :rid';
    One(Name, Sql);
  end;
  for I := 0 to High(GW_RECOUNT) do
    One(GW_RECOUNT[I].A, GW_RECOUNT[I].B);
end;

procedure AddEntry(A: TJSONArray; const Path, Kind, Key: string);
begin
  A.Add(TJSONObject.Create(['path', Path, 'kind', Kind, 'key', Key]));
end;

// Every file and folder the deletion frees, as journal entries; with the sets made.
function FilesToRemove(Db: TGwDb; const P: TGtPaths; const O: TGwOwner; RepoOnly: Boolean): TJSONArray;
var
  Rows: TGtRows;
  I: Integer;
  Lower, S: string;
begin
  Result := TJSONArray.Create;
  Lower := LowerCase(O.Name);
  if not RepoOnly then
    AddEntry(Result, GtPath([P.RepoRoot, Lower]), 'owner', Lower);
  Rows := Db.Query('SELECT lower(owner_name), lower_name FROM repository WHERE id IN d_repo', []);
  for I := 0 to High(Rows) do
    // A repository whose owner_name is stale (a renamed owner) has its folder elsewhere.
    if (Rows[I][0] <> '') and (RepoOnly or (Rows[I][0] <> Lower)) and GtNameIsSafe(Rows[I][0]) and
      GtRepoNameIsValid(Rows[I][1]) then
    begin
      AddEntry(Result, GtPath([P.RepoRoot, Rows[I][0], Rows[I][1] + '.git']), 'repo', Rows[I][0] + '/' + Rows[I][1]);
      AddEntry(Result, GtPath([P.RepoRoot, Rows[I][0], Rows[I][1] + '.wiki.git']), 'repo',
        Rows[I][0] + '/' + Rows[I][1]);
    end;
  Rows := Db.Query('SELECT lower(uuid) FROM attachment WHERE id IN d_attachment', []);
  for I := 0 to High(Rows) do
  begin
    S := Rows[I][0];
    if (Length(S) = 36) and IsHexText(StringReplace(S, '-', '', [rfReplaceAll])) then
      AddEntry(Result, GtPath([P.Attachments, S[1], S[2], S]), 'attachment', S);
  end;
  // An LFS object is shared: only those no other repository references.
  Rows := Db.Query('SELECT DISTINCT oid FROM lfs_meta_object WHERE repository_id IN d_repo AND oid NOT IN ' +
    '(SELECT oid FROM lfs_meta_object WHERE repository_id NOT IN d_repo)', []);
  for I := 0 to High(Rows) do
  begin
    S := Rows[I][0];
    if (Length(S) > 4) and IsHexText(S) then
      AddEntry(Result, GtPath([P.Lfs, Copy(S, 1, 2), Copy(S, 3, 2), Copy(S, 5, MaxInt)]), 'lfs', S);
  end;
  // A package blob is shared too.
  Rows := Db.Query('SELECT DISTINCT hash_sha256 FROM package_blob WHERE id IN (SELECT blob_id FROM package_file ' +
    'WHERE id IN d_pfile) AND id NOT IN (SELECT blob_id FROM package_file WHERE id NOT IN d_pfile)', []);
  for I := 0 to High(Rows) do
  begin
    S := Rows[I][0];
    if (Length(S) = 64) and IsHexText(S) then
      AddEntry(Result, GtPath([P.Packages, Copy(S, 1, 2), Copy(S, 3, 2), S]), 'package', S);
  end;
  if not RepoOnly and (O.Avatar <> '') and GtNameIsSafe(O.Avatar) and
    not Db.Has('SELECT 1 FROM user WHERE avatar = ?1 AND id <> ?2', [O.Avatar, O.Id]) then
    AddEntry(Result, GtPath([P.Avatars, O.Avatar]), 'avatar', O.Avatar);
  Rows := Db.Query('SELECT avatar FROM repository WHERE id IN d_repo AND COALESCE(avatar, '''') <> ''''', []);
  for I := 0 to High(Rows) do
    if GtNameIsSafe(Rows[I][0]) then
      AddEntry(Result, GtPath([P.RepoAvatars, Rows[I][0]]), 'avatar', Rows[I][0]);
  Rows := Db.Query('SELECT log_filename FROM action_task WHERE id IN d_task AND log_in_storage = 1 ' +
    'AND COALESCE(log_filename, '''') <> ''''', []);
  for I := 0 to High(Rows) do
    if NoDotDot(Rows[I][0]) then
      AddEntry(Result, GtPath([P.ActionsLog, Rows[I][0]]), 'actions_log', Rows[I][0]);
  Rows := Db.Query('SELECT storage_path FROM action_artifact WHERE id IN d_artifact ' +
    'AND COALESCE(storage_path, '''') <> ''''', []);
  for I := 0 to High(Rows) do
    if NoDotDot(Rows[I][0]) then
      AddEntry(Result, GtPath([P.ActionsArtifacts, Rows[I][0]]), 'artifact', Rows[I][0]);
  Rows := Db.Query('SELECT id FROM d_repo', []);
  for I := 0 to High(Rows) do
    AddEntry(Result, GtPath([P.RepoArchive, Rows[I][0]]), 'archive', Rows[I][0]);
end;

// Actions logs not yet moved to storage live in dbfs (models/dbfs).
function DbfsLogs(Db: TGwDb; Tables: TStringList): TStringArray;
var
  Rows: TGtRows;
  I, N, K: Integer;
  Full: string;
begin
  Result := nil;
  if Tables.IndexOf('dbfs_meta') < 0 then
    Exit;
  Rows := Db.Query('SELECT log_filename FROM action_task WHERE id IN d_task AND COALESCE(log_in_storage, 0) = 0 ' +
    'AND COALESCE(log_filename, '''') <> ''''', []);
  SetLength(Result, Length(Rows));
  for I := 0 to High(Rows) do
  begin
    Full := 'actions_log/' + Rows[I][0];
    N := 0;
    for K := 1 to Length(Full) do
      if Full[K] = '/' then
        Inc(N);
    Result[I] := IntToStr(N) + ':' + Full;
  end;
end;

function SqlList(const Items: TStringArray): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(Items) do
  begin
    if I > 0 then
      Result := Result + ', ';
    Result := Result + '''' + StringReplace(Items[I], '''', '''''', [rfReplaceAll]) + '''';
  end;
end;

function Blockers(Db: TGwDb; const O: TGwOwner): TJSONArray;
var
  Rows: TGtRows;
  I: Integer;
begin
  Result := TJSONArray.Create;
  if O.Kind <> 'user' then
    Exit;
  if O.IsAdmin and (Db.Scalar('SELECT COUNT(*) FROM user WHERE is_admin = 1 AND COALESCE(type, 0) = 0 AND id <> ?1',
    [O.Id]) = '0') then
    Result.Add('this is the last administrator');
  Rows := Db.Query('SELECT o.name FROM team t JOIN user o ON o.id = t.org_id JOIN team_user tu ON tu.team_id = t.id ' +
    'WHERE t.authorize = 4 AND tu.uid = ?1 AND (SELECT COUNT(*) FROM team_user x WHERE x.team_id = t.id) = 1', [O.Id]);
  for I := 0 to High(Rows) do
    Result.Add('the last owner of the organization ' + Rows[I][0] + ': delete or hand over ' + Rows[I][0] + ' first');
end;

// The plan, on a connection whose sets are made here.
function Plan(Db: TGwDb; const P: TGtPaths; const Owner, Repo: string; out O: TGwOwner; out Uid, Rid,
  IsUser: string; out Tables: TStringList): TJSONObject;
var
  Rows: TGtRows;
  Counts, ByKind: TJSONObject;
  Files, Existing: TJSONArray;
  Repos: TJSONArray;
  I: Integer;
  N, TotalRows, TotalBytes, TotalFiles, B: Int64;
  Path, Kind: string;
  Dbfs: TStringArray;
  RepoName: string;
begin
  O := FindOwner(Db, Owner);
  RepoName := '';
  if Repo <> '' then
  begin
    if not GtRepoNameIsValid(Repo) then
      raise EGw.Create('not a Gitea repository name: ''' + Repo + '''');
    Rows := Db.Query('SELECT id, name FROM repository WHERE owner_id = ?1 AND lower_name = ?2', [O.Id, LowerCase(Repo)]);
    if Length(Rows) = 0 then
      raise EGw.Create('no repository ' + O.Name + '/' + Repo + ' in Gitea');
    Uid := '-1';
    Rid := Rows[0][0];
    IsUser := '0';
    RepoName := Rows[0][1];
  end
  else
  begin
    Uid := O.Id;
    Rid := '-1';
    IsUser := ifthen_(O.Kind = 'user', '1', '0');
  end;
  Tables := Db.Tables;
  MakeSets(Db, Tables, Uid, Rid, IsUser, Repo <> '');
  Counts := TJSONObject.Create;
  TotalRows := 0;
  for I := 0 to High(GW_DELETES) do
    if Tables.IndexOf(GW_DELETES[I].A) >= 0 then
    begin
      N := StrToInt64Def(Db.Scalar('SELECT COUNT(*) FROM `' + GW_DELETES[I].A + '` WHERE ' +
        Bind(GW_DELETES[I].B, Uid, Rid, IsUser), []), 0);
      if N > 0 then
      begin
        Counts.Add(GW_DELETES[I].A, N);
        Inc(TotalRows, N);
      end;
    end;
  Dbfs := DbfsLogs(Db, Tables);
  if Length(Dbfs) > 0 then
  begin
    N := StrToInt64Def(Db.Scalar('SELECT COUNT(*) FROM dbfs_meta WHERE full_path IN (' + SqlList(Dbfs) + ')', []), 0);
    Counts.Add('dbfs_meta', N);
    Inc(TotalRows, N);
  end;
  Files := FilesToRemove(Db, P, O, Repo <> '');
  Existing := TJSONArray.Create;
  ByKind := TJSONObject.Create;
  TotalBytes := 0;
  TotalFiles := 0;
  for I := 0 to Files.Count - 1 do
  begin
    Path := TJSONObject(Files.Items[I]).Get('path', '');
    if not GtExists(Path) then
      Continue;
    Existing.Add(Files.Items[I].Clone);
    B := PathBytes(Path);
    Inc(TotalBytes, B);
    Inc(TotalFiles, PathFiles(Path));
    Kind := TJSONObject(Files.Items[I]).Get('kind', '');
    if Kind = 'repo' then
      Kind := ifthen_(Copy(Path, Length(Path) - 8, 9) = '.wiki.git', 'wiki', 'git');
    if ByKind.Find(Kind) = nil then
      ByKind.Add(Kind, B)
    else
      ByKind.Int64s[Kind] := ByKind.Int64s[Kind] + B;
  end;
  Files.Free;
  Repos := TJSONArray.Create;
  Rows := Db.Query('SELECT name FROM repository WHERE id IN d_repo ORDER BY lower_name', []);
  for I := 0 to High(Rows) do
    Repos.Add(Rows[I][0]);
  Result := TJSONObject.Create;
  Result.Add('owner', O.Name);
  Result.Add('id', StrToInt64Def(O.Id, 0));
  Result.Add('kind', O.Kind);
  if Repo <> '' then
    Result.Add('repository', RepoName)
  else
    Result.Add('repository', TJSONNull.Create);
  Result.Add('repositories', Repos);
  Result.Add('tables', Counts);
  Result.Add('rows', TotalRows);
  Result.Add('files', TotalFiles);
  Result.Add('bytes', TotalBytes);
  Result.Add('bytes_by_kind', ByKind);
  Result.Add('paths', Existing);
  // Gitea unlinks a package from a deleted repository; it stays the owner's.
  if Tables.IndexOf('package') >= 0 then
    Result.Add('packages_unlinked', StrToInt64Def(Db.Scalar('SELECT COUNT(*) FROM package WHERE repo_id IN d_repo', []), 0))
  else
    Result.Add('packages_unlinked', 0);
  if Repo <> '' then
    Result.Add('blocked', TJSONArray.Create)
  else
    Result.Add('blocked', Blockers(Db, O));
end;

function GwPlanDelete(const P: TGtPaths; const Owner, Repo: string): TJSONObject;
var
  Db: TGwDb;
  O: TGwOwner;
  Uid, Rid, IsUser: string;
  Tables: TStringList;
begin
  Tables := nil;
  Db := TGwDb.Open(P.DbPath, True);
  try
    Result := Plan(Db, P, Owner, Repo, O, Uid, Rid, IsUser, Tables);
  finally
    Tables.Free;
    Db.Free;
  end;
end;

{ --- the record of deletions, the size index ------------------------------- }

function GwDeletedLogPath(const P: TGtPaths): string;
begin
  Result := GtPath([P.AppDataPath, 'omi', 'deleted-repos.tsv']);
end;

function Clean(const S: string): string;
var
  I: Integer;
begin
  Result := S;
  for I := 1 to Length(Result) do
    if Result[I] in [#9, #10, #13] then
      Result[I] := ' ';
  Result := Trim(Result);
end;

// One line per deletion: owner/name TAB UTC time TAB bytes freed TAB Omi user TAB kind.
procedure RecordDeletion(const P: TGtPaths; const Full: string; Bytes: Int64; const By, Kind: string);
var
  Line, Path: string;
begin
  Path := GwDeletedLogPath(P);
  GtForceDirs(ExtractFileDir(Path));
  Line := Clean(Full) + #9 + UtcNow + #9 + IntToStr(Bytes) + #9 + Clean(By) + #9 + Kind + #10;
  GtAppendSynced(Path, Line);
end;

// The size index without the lines of what was removed, and marked stale.
procedure MarkIndex(const IndexPath: string; Removed: TJSONArray; const P: TGtPaths);
var
  Lines, Gone: TStringList;
  Parts: TStringArray;
  I, K: Integer;
  Full, Root, Text: string;

  function IsGone(const Path: string): Boolean;
  var
    X: string;
    J: Integer;
  begin
    X := ExpandFileName(Path);
    for J := 0 to Gone.Count - 1 do
      if (X = Gone[J]) or GtUnder(Gone[J], X) then
        Exit(True);
    Result := False;
  end;

begin
  if (IndexPath = '') or not FileExists(IndexPath) then
    Exit;
  Lines := TStringList.Create;
  Gone := TStringList.Create;
  try
    for I := 0 to Removed.Count - 1 do
      Gone.Add(ExpandFileName(TJSONObject(Removed.Items[I]).Get('path', '')));
    Lines.LoadFromFile(IndexPath);
    Text := '';
    for I := 0 to Lines.Count - 1 do
    begin
      Parts := Lines[I].Split([#9]);
      if Length(Parts) = 0 then
        Continue;
      if Parts[0] = '#stale' then
        Continue;
      if (Parts[0] = 'R') and (Length(Parts) >= 3) and IsGone(GtPath([P.RepoRoot, Parts[1], Parts[2]])) then
        Continue;
      Root := '';
      case Parts[0] of
        'A': Root := P.Attachments;
        'L': Root := P.Lfs;
        'P': Root := P.Packages;
        'V': Root := P.Avatars;
        'W': Root := P.RepoAvatars;
        'G': Root := P.ActionsLog;
        'F': Root := P.ActionsArtifacts;
        'X': Root := P.RepoArchive;
      end;
      if (Root <> '') and (Length(Parts) >= 2) then
      begin
        Full := GtPath([Root, Parts[1]]);
        if IsGone(Full) then
          Continue;
      end;
      Text := Text + Lines[I] + #10;
    end;
    Text := Text + '#stale'#9 + UtcNow + #10;
    K := 0;
    ReplaceFile(IndexPath, Text);
    if K = 0 then;
  finally
    Lines.Free;
    Gone.Free;
  end;
end;

{ --- the exclude file --------------------------------------------------------- }

function GwParseExcludes(const Text: string): TStringList;
var
  Lines: TStringList;
  I, H: Integer;
  S: string;
  Parts: TStringArray;
  K: Integer;
begin
  Result := TStringList.Create;
  Lines := TStringList.Create;
  try
    Lines.Text := Text;
    for I := 0 to Lines.Count - 1 do
    begin
      S := Lines[I];
      H := Pos('#', S);
      if H > 0 then
        S := Copy(S, 1, H - 1);
      Parts := S.Split([',']);
      for K := 0 to High(Parts) do
        if Trim(Parts[K]) <> '' then
          Result.Add(Trim(Parts[K]));
    end;
  finally
    Lines.Free;
  end;
end;

function GwExcludeList(const Path: string): TStringList;
begin
  if (Path <> '') and FileExists(Path) then
    Result := GwParseExcludes(ReadSmallFile(Path))
  else
    Result := TStringList.Create;
end;

function GwExcludeCheck(const Full: string): Boolean;
var
  Parts: TStringArray;
begin
  Parts := Full.Split(['/']);
  Result := (Length(Parts) = 2) and GtNameIsSafe(Parts[0]) and GtRepoNameIsValid(Parts[1]);
end;

function GwIsExcluded(const Path, Full: string): Boolean;
var
  L: TStringList;
  I: Integer;
begin
  Result := False;
  L := GwExcludeList(Path);
  try
    for I := 0 to L.Count - 1 do
      if SameText(L[I], Full) then
        Exit(True);
  finally
    L.Free;
  end;
end;

procedure GwExcludeAdd(const Path, Full: string);
var
  Text: string;
begin
  if not GwExcludeCheck(Full) then
    raise EGw.Create('not an owner/name of a repository: ''' + Full + '''');
  if Path = '' then
    raise EGw.Create('SYNC_EXCLUDE_FILE is not set');
  if GwIsExcluded(Path, Full) then
    Exit;
  if FileExists(Path) then
    Text := ReadSmallFile(Path)
  else
    Text := '# Repositories github-to-gitea and Omi no longer sync: owner/name, one a line.'#10;
  if (Text <> '') and (Text[Length(Text)] <> #10) then
    Text := Text + #10;
  ReplaceFile(Path, Text + Full + #10);
end;

function GwExcludeRemove(const Path, Full: string): Boolean;
var
  Lines, Names: TStringList;
  I, K: Integer;
  Text, Rest: string;
  Found, Here: Boolean;
begin
  if not GwExcludeCheck(Full) then
    raise EGw.Create('not an owner/name of a repository: ''' + Full + '''');
  Result := False;
  if (Path = '') or not FileExists(Path) then
    Exit;
  Lines := TStringList.Create;
  try
    Lines.Text := ReadSmallFile(Path);
    Text := '';
    Found := False;
    for I := 0 to Lines.Count - 1 do
    begin
      Names := GwParseExcludes(Lines[I]);
      try
        Here := False;
        Rest := '';
        for K := 0 to Names.Count - 1 do
          if SameText(Names[K], Full) then
            Here := True
          else
            Rest := Rest + ifthen_(Rest <> '', ', ', '') + Names[K];
        if Here then
        begin
          Found := True;
          if Rest <> '' then
            Text := Text + Rest + #10;
        end
        else
          Text := Text + Lines[I] + #10;
      finally
        Names.Free;
      end;
    end;
    if Found then
      ReplaceFile(Path, Text);
    Result := Found;
  finally
    Lines.Free;
  end;
end;

{ --- the deletion --------------------------------------------------------------- }

function GwDelete(const P: TGtPaths; const Owner, Repo, Confirm, PidFile, ExcludeFile, By,
  IndexPath: string; ExcludeFromSync: Boolean; Say: TGwSay): TJSONObject;
var
  W: TGwWriter;
  Db: TGwDb;
  O: TGwOwner;
  Uid, Rid, IsUser, Target, Full, MapPath: string;
  Tables: TStringList;
  PlanJ, Deleted: TJSONObject;
  Paths: TJSONArray;
  I: Integer;
  N, Total, Removed, Steps, Done: Int64;
  Dbfs, Shas: TStringArray;
  Excluded: Boolean;
begin
  Steps := 0;
  Done := 0;
  if not GtNameIsSafe(Owner) then
    raise EGw.Create('not a Gitea owner name: ''' + Owner + '''');
  if (Repo <> '') and not GtRepoNameIsValid(Repo) then
    raise EGw.Create('not a Gitea repository name: ''' + Repo + '''');
  if Repo <> '' then
    Target := Owner + '/' + Repo
  else
    Target := Owner;
  if Confirm <> Target then
    raise EGw.Create('The name typed is not ' + ifthen_(Repo <> '', 'the repository', 'the owner') +
      '''s name. Nothing was deleted.');
  W := TGwWriter.Enter(P, PidFile, Say);
  PlanJ := nil;
  Deleted := TJSONObject.Create;
  Tables := nil;
  try
    Db := TGwDb.Open(P.DbPath, False);
    try
      // The GitHub mapping of imports goes in the same transaction (ATTACH
      // comes before BEGIN).
      MapPath := GtPath([P.AppDataPath, 'omi', 'github-map.db']);
      if FileExists(MapPath) then
        Db.Exec('ATTACH DATABASE ?1 AS omimap', [MapPath]);
      Db.Exec('BEGIN IMMEDIATE', []);
      try
        if Assigned(Say) then
          Say('Planning the delete of ' + Target + ': the rows and the files it removes.');
        PlanJ := Plan(Db, P, Owner, Repo, O, Uid, Rid, IsUser, Tables);
        if TJSONArray(PlanJ.Find('blocked')).Count > 0 then
          raise EGw.Create('Cannot delete ' + Owner + ': ' + TJSONArray(PlanJ.Find('blocked')).Strings[0]);
        Paths := TJSONArray(PlanJ.Find('paths'));
        Dbfs := DbfsLogs(Db, Tables);
        // The files go after the commit; say which first.
        W.WriteJournal('delete ' + Target, Paths);
        // Progress: one step per table, one for the commit, one per file or
        // folder removed after it.
        Steps := 1 + Paths.Count;
        for I := 0 to High(GW_DELETES) do
          if Tables.IndexOf(GW_DELETES[I].A) >= 0 then
            Inc(Steps);
        Done := 0;
        GwProgress(Say, Done, Steps, 'rows');
        Total := 0;
        for I := 0 to High(GW_DELETES) do
          if Tables.IndexOf(GW_DELETES[I].A) >= 0 then
          begin
            N := Db.Changes('DELETE FROM `' + GW_DELETES[I].A + '` WHERE ' + Bind(GW_DELETES[I].B, Uid, Rid, IsUser), []);
            if N > 0 then
            begin
              Deleted.Add(GW_DELETES[I].A, N);
              Inc(Total, N);
            end;
            Inc(Done);
            GwProgress(Say, Done, Steps, 'rows: ' + GW_DELETES[I].A + ' ' + IntToStr(N));
          end;
        if Length(Dbfs) > 0 then
        begin
          Db.Exec('DELETE FROM dbfs_data WHERE meta_id IN (SELECT id FROM dbfs_meta WHERE full_path IN (' +
            SqlList(Dbfs) + '))', []);
          N := Db.Changes('DELETE FROM dbfs_meta WHERE full_path IN (' + SqlList(Dbfs) + ')', []);
          Deleted.Add('dbfs_meta', N);
          Inc(Total, N);
        end;
        // Blobs no package file uses any more.
        Shas := nil;
        for I := 0 to Paths.Count - 1 do
          if TJSONObject(Paths.Items[I]).Get('kind', '') = 'package' then
          begin
            SetLength(Shas, Length(Shas) + 1);
            Shas[High(Shas)] := TJSONObject(Paths.Items[I]).Get('key', '');
          end;
        if (Length(Shas) > 0) and (Tables.IndexOf('package_blob') >= 0) then
        begin
          N := Db.Changes('DELETE FROM package_blob WHERE hash_sha256 IN (' + SqlList(Shas) + ')', []);
          Deleted.Add('package_blob', N);
          Inc(Total, N);
        end;
        for I := 0 to High(GW_RECOUNT) do
          Db.Exec(Bind(GW_RECOUNT[I].C, Uid, Rid, IsUser), []);
        for I := 0 to High(GW_AFTER) do
          Db.Exec(Bind(GW_AFTER[I], Uid, Rid, IsUser), []);
        if FileExists(MapPath) then
        begin
          if Db.Has('SELECT 1 FROM omimap.sqlite_master WHERE name = ''owner_map''', []) then
            Db.Exec('DELETE FROM omimap.owner_map WHERE gitea_id = ' + Uid, []);
          if Db.Has('SELECT 1 FROM omimap.sqlite_master WHERE name = ''item_map''', []) then
            Db.Exec('DELETE FROM omimap.item_map WHERE repo_id IN d_repo', []);
          if Db.Has('SELECT 1 FROM omimap.sqlite_master WHERE name = ''repo_map''', []) then
            Db.Exec('DELETE FROM omimap.repo_map WHERE gitea_id IN d_repo', []);
        end;
        Db.Exec('COMMIT', []);
        Inc(Done);
        GwProgress(Say, Done, Steps, 'rows committed: ' + IntToStr(Total));
      except
        Db.Exec('ROLLBACK', []);
        FreeAndNil(Db);
        // Nothing was deleted: the journal's files are all still referenced.
        W.FinishJournal;
        raise;
      end;
    finally
      Db.Free;
    end;
    W.ProgressDone := Done;
    W.ProgressTotal := Steps;
    Removed := W.FinishJournal;
    W.ProgressTotal := 0;
    if Repo <> '' then
      Full := PlanJ.Get('owner', '') + '/' + PlanJ.Get('repository', '')
    else
      Full := PlanJ.Get('owner', '');
    RecordDeletion(P, Full, PlanJ.Int64s['bytes'], By, ifthen_(Repo <> '', 'repository', PlanJ.Get('kind', '')));
    MarkIndex(IndexPath, Paths, P);
    Excluded := False;
    if (Repo <> '') and ExcludeFromSync and (ExcludeFile <> '') then
    begin
      GwExcludeAdd(ExcludeFile, Full);
      Excluded := True;
    end;
    if Assigned(Say) then
      Say('Deleted ' + Full + ': ' + IntToStr(Total) + ' rows, ' + IntToStr(Removed) + ' files, ' +
        IntToStr(PlanJ.Int64s['bytes']) + ' bytes freed.');
    Result := TJSONObject.Create;
    Result.Add('owner', PlanJ.Get('owner', ''));
    if Repo <> '' then
      Result.Add('repository', PlanJ.Get('repository', ''))
    else
      Result.Add('repository', TJSONNull.Create);
    Result.Add('tables', Deleted);
    Deleted := nil;
    Result.Add('rows', Total);
    Result.Add('files', Removed);
    Result.Add('bytes', PlanJ.Int64s['bytes']);
    Result.Add('bytes_by_kind', PlanJ.Find('bytes_by_kind').Clone);
    Result.Add('excluded', Excluded);
  finally
    Deleted.Free;
    PlanJ.Free;
    Tables.Free;
    W.Free;
  end;
end;

{ --- deleting the orphans ------------------------------------------------------ }

function GwDeleteOrphans(const P: TGtPaths; const Confirm, PidFile, IndexPath: string; Say: TGwSay): TJSONObject;
var
  W: TGwWriter;
  Db: TGwDb;
  R: TGtReport;
  E, Kind, Rel, Key, Reason, Root, RefKind: string;
  Parts: TStringArray;
  Entries: TJSONArray;
  I: Integer;
  Bytes, Rows, Kept, Removed, Size: Int64;

  function AttachmentFile(const Uuid: string): string;
  begin
    Result := GtPath([P.Attachments, Copy(Uuid, 1, 1), Copy(Uuid, 2, 1), Uuid]);
  end;

  function LfsFile(const Oid: string): string;
  begin
    Result := GtPath([P.Lfs, Copy(Oid, 1, 2), Copy(Oid, 3, 2), Copy(Oid, 5, MaxInt)]);
  end;

begin
  if IndexPath = '' then
    raise EGw.Create('no size index: measure the Gitea folder first');
  W := TGwWriter.Enter(P, PidFile, Say);
  Entries := TJSONArray.Create;
  R := Default(TGtReport);
  try
    if not GtLoadReport(P, IndexPath, R, E) then
      raise EGw.Create('cannot read the size index: ' + E);
    if Trim(Confirm) <> IntToStr(R.Orphans.Count) then
      raise EGw.Create('The number typed is not the number of orphans (' + IntToStr(R.Orphans.Count) +
        '). Nothing was deleted.');
    Bytes := 0;
    Rows := 0;
    Kept := 0;
    Db := TGwDb.Open(P.DbPath, False);
    try
      Db.Exec('BEGIN IMMEDIATE', []);
      try
        for I := 0 to R.Orphans.Count - 1 do
        begin
          Parts := R.Orphans[I].Split([#9]);
          if Length(Parts) < 4 then
            Continue;
          Kind := Parts[0];
          Rel := Parts[1];
          Size := StrToInt64Def(Parts[2], 0);
          Reason := Parts[3];
          Root := '';
          RefKind := '';
          Key := '';
          case Kind of
            'attachment-file':
              begin
                Root := P.Attachments;
                RefKind := 'attachment';
                Key := ExtractFileName(Rel);
              end;
            'lfs-file':
              begin
                Root := P.Lfs;
                RefKind := 'lfs';
                Key := LowerCase(StringReplace(Rel, '/', '', [rfReplaceAll]));
              end;
            'package-file':
              begin
                Root := P.Packages;
                RefKind := 'package';
                Key := LowerCase(ExtractFileName(Rel));
              end;
            'avatar-file':
              begin
                Root := P.Avatars;
                RefKind := 'avatar';
                Key := Rel;
              end;
            'repo-avatar-file':
              begin
                Root := P.RepoAvatars;
                RefKind := 'avatar';
                Key := Rel;
              end;
            'git-directory':
              begin
                Root := P.RepoRoot;
                RefKind := 'repo';
                Key := LowerCase(Rel);
                if Copy(Key, Length(Key) - 8, 9) = '.wiki.git' then
                  Key := Copy(Key, 1, Length(Key) - 9)
                else if Copy(Key, Length(Key) - 3, 4) = '.git' then
                  Key := Copy(Key, 1, Length(Key) - 4);
              end;
            'attachment-row':
              // Only while its file is still not there.
              if not FileExists(AttachmentFile(Rel)) then
              begin
                Inc(Rows, Db.Changes('DELETE FROM attachment WHERE uuid = ?1', [Rel]));
                Continue;
              end;
            'lfs-row':
              begin
                if Copy(Reason, 1, 7) = 'its rep' then
                  Inc(Rows, Db.Changes('DELETE FROM lfs_meta_object WHERE oid = ?1 AND ' +
                    'repository_id NOT IN (SELECT id FROM repository)', [Rel]))
                else if not FileExists(LfsFile(Rel)) then
                  Inc(Rows, Db.Changes('DELETE FROM lfs_meta_object WHERE oid = ?1', [Rel]));
                Continue;
              end;
          end;
          if (Root = '') or not NoDotDot(Rel) then
          begin
            Inc(Kept);
            if Assigned(Say) then
              Say('Kept: ' + Kind + ' ' + Rel + ' (' + Reason + ')');
            Continue;
          end;
          Entries.Add(TJSONObject.Create(['kind', RefKind, 'key', Key, 'path', GtPath([Root, Rel])]));
          Inc(Bytes, Size);
        end;
        // The files go after the commit; say which first.
        W.WriteJournal('delete orphans', Entries);
        Db.Exec('COMMIT', []);
      except
        Db.Exec('ROLLBACK', []);
        FreeAndNil(Db);
        if FileExists(W.JournalPath) then
          DeleteFile(W.JournalPath);
        raise;
      end;
    finally
      Db.Free;
    end;
    if Assigned(Say) then
      Say('Orphans: ' + IntToStr(R.Orphans.Count) + '; rows deleted: ' + IntToStr(Rows) + '; files to remove: ' +
        IntToStr(Entries.Count) + ', ' + IntToStr(Bytes) + ' bytes; kept: ' + IntToStr(Kept) + '.');
    GwStatus(Say, 'toremove', IntToStr(Entries.Count) + ' ' + IntToStr(Bytes));
    W.ProgressDone := 0;
    W.ProgressTotal := Entries.Count;
    Removed := W.FinishJournal;
    MarkIndex(IndexPath, Entries, P);
    if Assigned(Say) then
      Say('Deleted the orphans: ' + IntToStr(Rows) + ' rows, ' + IntToStr(Removed) + ' files, ' +
        IntToStr(W.ProgressBytes) + ' bytes freed.');
    Result := TJSONObject.Create(['orphans', R.Orphans.Count, 'rows', Rows, 'files', Removed,
      'bytes', W.ProgressBytes, 'kept', Kept]);
  finally
    GtFreeReport(R);
    Entries.Free;
    W.Free;
  end;
end;

{$I omigiteai.inc}

end.
