
--migrator.sql
--migrates the tickets database to the redmine database
--usage: sqlite3 < migrator.sql
--claude gierl
--version01 27.02.15

attach database 'tickets.db' as 'tic';
attach database 'redmine.sqlite3' as 'rm';

----system level options
INSERT INTO rm.settings (name, value) values ('default_language', 'en-GB');

----query_type to tracker
--keep the default redmine items 'Bug','Feature', 'Support', not used in tickets
--add 'Data', 'Documentation'...
INSERT INTO rm.trackers (name)
    SELECT name
    FROM tic.query_type;

----status to issue_statuses
--TICKETS		REDMINE
--Logged		New
--Allocated		(add)
--In Progress		In Progress
--Awaiting Info		Feedback
--Cancelled		Rejected
--Resolved		Resolved
--Unresolved		(add)
--			Closed
--schema is name, closed, position...
--update the position of the ones below before inserting
UPDATE rm.issue_statuses set position = position + 1 where position > 1;
INSERT INTO rm.issue_statuses (name, is_closed, position) values ('Allocated', 'f', 2);
INSERT INTO rm.issue_statuses (name, is_closed, position) values ('Unresolved', 't', 8);
--we consider resolved as being closed, whereas in redmine it was not closed
UPDATE rm.issue_statuses set is_closed = 't' where name = 'Resolved';

--create a temporary mapping table 'old id to new id' for easier job migration
CREATE TEMP TABLE status_mapping ( tickets_id integer, redmine_id integer);
INSERT INTO status_mapping SELECT tic.status.id, rm.issue_statuses.id FROM tic.status, rm.issue_statuses WHERE tic.status.name = 'Logged' AND rm.issue_statuses.name = 'New';
INSERT INTO status_mapping SELECT tic.status.id, rm.issue_statuses.id FROM tic.status, rm.issue_statuses WHERE tic.status.name = 'Allocated' AND rm.issue_statuses.name = 'Allocated';
INSERT INTO status_mapping SELECT tic.status.id, rm.issue_statuses.id FROM tic.status, rm.issue_statuses WHERE tic.status.name = 'In Progress' AND rm.issue_statuses.name = 'In Progress';
INSERT INTO status_mapping SELECT tic.status.id, rm.issue_statuses.id FROM tic.status, rm.issue_statuses WHERE tic.status.name = 'Awaiting Info' AND rm.issue_statuses.name = 'Feedback';
INSERT INTO status_mapping SELECT tic.status.id, rm.issue_statuses.id FROM tic.status, rm.issue_statuses WHERE tic.status.name =  'Cancelled' AND rm.issue_statuses.name = 'Rejected';
INSERT INTO status_mapping SELECT tic.status.id, rm.issue_statuses.id FROM tic.status, rm.issue_statuses WHERE tic.status.name = 'Resolved' AND rm.issue_statuses.name = 'Resolved';
INSERT INTO status_mapping SELECT tic.status.id, rm.issue_statuses.id FROM tic.status, rm.issue_statuses WHERE tic.status.name = 'Unresolved' AND rm.issue_statuses.name = 'Unresolved';

----add worklow for new trackers for role Manager (all possible transitions)
--I don't add anything for the default trackers (1,2,3)
INSERT INTO rm.workflows (tracker_id, old_status_id, new_status_id, role_id, type)
	SELECT rm.trackers.id, os.id, ns.id, rm.roles.id, "WorkflowTransition"
	FROM rm.trackers, rm.issue_statuses as os, rm.issue_statuses as ns, rm.roles
	WHERE rm.trackers.id > 3
	AND rm.roles.name = "Manager"
	AND os.id != ns.id;

----severity to enumerations.name with type='IssuePriority'
--TICKETS		REDMINE
--Critical		Immediate
--Urgent		Urgent
--			High
--Normal		Normal
--Low			Low
--create a temporary mapping table 'old id to new id' for easier job migration
CREATE TEMP TABLE priority_mapping ( tickets_id integer, redmine_id integer);
INSERT INTO priority_mapping SELECT tic.severity.id, rm.enumerations.id FROM tic.severity, rm.enumerations WHERE tic.severity.name = 'Critical' AND rm.enumerations.type = 'IssuePriority' AND rm.enumerations.name = 'Immediate';
INSERT INTO priority_mapping SELECT tic.severity.id, rm.enumerations.id FROM tic.severity, rm.enumerations WHERE tic.severity.name = 'Urgent' AND rm.enumerations.type = 'IssuePriority' AND rm.enumerations.name = 'Urgent';
INSERT INTO priority_mapping SELECT tic.severity.id, rm.enumerations.id FROM tic.severity, rm.enumerations WHERE tic.severity.name = 'Normal' AND rm.enumerations.type = 'IssuePriority' AND rm.enumerations.name = 'Normal';
INSERT INTO priority_mapping SELECT tic.severity.id, rm.enumerations.id FROM tic.severity, rm.enumerations WHERE tic.severity.name = 'Low' AND rm.enumerations.type = 'IssuePriority' AND rm.enumerations.name = 'Low';

----survey and sweep to projects
--"Tickets" is the top-level project, the surveys are second-level and the sweeps third-level.
--the 'n/a' survey with its 'n/a' sweep becomes a second-level project.
--apart from 'n/a' sweep and survey names are unique within a joint set.
INSERT INTO rm.projects (name, identifier) values ("Tickets", "Tickets");
INSERT INTO rm.projects (name, identifier, parent_id, inherit_members)
	SELECT tic.survey.name, tic.survey.name, rm.projects.id, "t"
	FROM tic.survey, rm.projects
	WHERE rm.projects.name = "Tickets";
INSERT INTO rm.projects (name, identifier, parent_id, inherit_members)
	SELECT tic.sweep.name, tic.sweep.name, rm.projects.id, "t"
	FROM tic.sweep, tic.survey, rm.projects
	WHERE tic.sweep.survey_id = tic.survey.id
	AND tic.survey.name = rm.projects.name
	AND tic.sweep.name != "n/a";

--edit name and identifier where it contains a '/' (creates problems in redmine paths)
UPDATE rm.projects SET name = replace( name, '/', '-' ), identifier = replace( identifier, '/', '-' ) WHERE name LIKE '%/%';

--add nested sets values
--The projects use a 'nested set' structure.
--I assume tickets, then level1 and level2 and that they have been entered in the right order
--insert rigth and left values, projects don't display without it
--tickets, i.e. root project:
UPDATE rm.projects set lft = 1, rgt = 2*(SELECT COUNT(*) FROM rm.projects) WHERE id = 1;
--level1 lft: count lft root + 1 + 2* the level1s before it + 2* the children thereof
UPDATE rm.projects SET lft = 2 + 2*(SELECT COUNT(p1.id) FROM rm.projects as p1 WHERE p1.id < rm.projects.id AND p1.parent_id = 1)
	+ 2*(SELECT count(p2.id) FROM rm.projects as p1, rm.projects as p2 WHERE p1.id < rm.projects.id AND p1.parent_id = 1 AND p2.parent_id = p1.id)
	WHERE rm.projects.parent_id = 1;
--level1 rgt: count lft root + 2* the level1s before including itself + 2* the children thereof
UPDATE rm.projects SET rgt = 1 + 2*(SELECT COUNT(p1.id) FROM rm.projects as p1 WHERE p1.id <= rm.projects.id AND p1.parent_id = 1)
	+ 2*(SELECT count(p2.id) FROM rm.projects as p1, rm.projects as p2 WHERE p1.id <= rm.projects.id AND p1.parent_id = 1 AND p2.parent_id = p1.id)
	WHERE rm.projects.parent_id = 1;
--level2 lft: count lft root + 1 + 2* the level1s before it + 2* the children thereof + 1 + 2* the children of its parent if positioned before
UPDATE rm.projects SET lft = 2 + 2*(SELECT COUNT(p1.id) FROM rm.projects as p1 WHERE p1.id < rm.projects.parent_id AND p1.parent_id = 1)
	+ 2*(SELECT count(p2.id) FROM rm.projects as p1, rm.projects as p2 WHERE p1.id < rm.projects.parent_id AND p1.parent_id = 1 AND p2.parent_id = p1.id)
	+ 1 + 2*(SELECT COUNT(p2.id) FROM rm.projects as p2 WHERE p2.id < rm.projects.id AND p2.parent_id = rm.projects.parent_id)
	WHERE rm.projects.parent_id IS NOT NULL AND rm.projects.parent_id != 1;
--level2 rgt: lft + 1 as there is no level 3
UPDATE rm.projects SET rgt = lft + 1
	WHERE rm.projects.parent_id IS NOT NULL AND rm.projects.parent_id != 1;

--create a temporary mapping table 'old id to new id' for easier job migration
CREATE TEMP TABLE sweep_mapping ( tickets_id integer, redmine_id integer);
INSERT INTO sweep_mapping SELECT tic.sweep.id, rm.projects.id
	FROM tic.sweep, rm.projects
	WHERE tic.sweep.name = rm.projects.name;
	
--edit project names to avoid redmine GUI problems
UPDATE rm.projects SET name = "Tickets - General", identifier = "Tickets - General"
	WHERE name = "n/a";
UPDATE rm.projects SET name = substr(name, 10) || " - General", identifier = substr(name, 10) || " - General"
	WHERE name like 'General,%';

----enabled modules in projects
CREATE TEMP TABLE modules (name varchar(255));
INSERT INTO modules (name) values ("issue_tracking");
INSERT INTO modules (name) values ( "time_tracking");
--INSERT INTO modules (name) values ( "news");
--INSERT INTO modules (name) values ( "documents");
--INSERT INTO modules (name) values ( "files");
INSERT INTO modules (name) values ( "wiki");
--INSERT INTO modules (name) values ( "repository");
--INSERT INTO modules (name) values ( "forums");
INSERT INTO modules (name) values ( "calendar");
INSERT INTO modules (name) values ( "gantt");

INSERT INTO rm.enabled_modules (project_id, name)
	SELECT rm.projects.id, modules.name
	FROM rm.projects, modules;

----associate trackers to projects
--the first 3 trackers (Bug, Feature, Support) are default redmine trackers and are ignored
INSERT INTO rm.projects_trackers (project_id, tracker_id)
	SELECT rm.projects.id, rm.trackers.id
	FROM rm.projects, rm.trackers
	WHERE rm.trackers.id > 3; 


----issue categories
--they don't exist in tickets and seem optional in redmine


----people
--in jobs:
--logger may fit author_id
--assignee to assigned_to_id
--originator was the client, need to create custom field on an issue
--category table was created but not used in tickets
--I create groups in the users table with type 'Group'
--tickets-client group has no role/rights but is used for a custom field
--tickets-fixer group has no rights
--tickets-manager group has logging rights
--tickets-admin group has all rights on the tickets project
--in tickets there were a few people who were fixers but not clients, but this is not important
--I assume that users get the permissions of the most powerful they belong to and/or that they can move to a new group
INSERT INTO rm.users (lastname, type) values ('Tickets-clients-ext', 'Group');
INSERT INTO rm.users (lastname, type) values ('Tickets-clients-ioe', 'Group');
INSERT INTO rm.users (lastname, type) values ('Tickets-fixers', 'Group');
INSERT INTO rm.users (lastname, type) values ('Tickets-managers', 'Group');
INSERT INTO rm.users (lastname, type) values ('Tickets-admin', 'Group');

--I put the first part of the tickets display name into first name, the rest into surname, to be cleaned up manually.
--for the lastname I left-trim anything but space (alpha, hyphen or dash) then trim again for spaces
--for the first name I replace the lastname with nothing then trim
--n.b. instr() is not available on our version of sqlite3
INSERT INTO rm.users (login, firstname, lastname, mail, type) 
	SELECT ifnull(user_name, ''),
	TRIM(REPLACE(display_name, LTRIM(display_name, '.-ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'),'')),
	TRIM(LTRIM(display_name, '.-ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz')),
	ifnull(email_address, ''),
	'User'
	FROM tic.tg_user
	WHERE tic.tg_user.display_name != 'demo'
	AND tic.tg_user.display_name != 'xxxxxxxx';

--I enter into Tickets-clients-ext the tickets users who had a non-ioe email address (and therefore no access)
--the id=1 to exclude is a redmine default admin User
INSERT INTO rm.groups_users
	SELECT groups.id, people.id
	FROM rm.users as groups, rm.users as people
	WHERE groups.lastname = 'Tickets-clients-ext'
	AND people.mail NOT LIKE '%@ioe%'
	AND people.type = 'User'
	AND people.id !=1;

--I enter into Tickets-clients-ioe the tickets users who have an ioe email and are only 'client'
INSERT INTO rm.groups_users
	SELECT groups.id, people.id
	FROM rm.users as groups, rm.users as people, tic.tg_user, tic.tg_group, tic.user_group
	WHERE groups.lastname = 'Tickets-clients-ioe'
	AND people.mail LIKE '%@ioe%'
	AND people.mail = tic.tg_user.email_address
	AND tic.tg_user.user_id = tic.user_group.user_id
	AND tic.tg_group.group_id = tic.user_group.group_id
	GROUP BY people.id
	HAVING GROUP_CONCAT(tic.tg_group.group_name)='client';

--I enter into Tickets-admin the tickets users who have an ioe email and are 'admin' (don't care about other groups)
INSERT INTO rm.groups_users
	SELECT groups.id, people.id
	FROM rm.users as groups, rm.users as people, tic.tg_user, tic.tg_group, tic.user_group
	WHERE groups.lastname = 'Tickets-admin'
	AND people.mail LIKE '%@ioe%'
	AND people.mail = tic.tg_user.email_address
	AND tic.tg_user.user_id = tic.user_group.user_id
	AND tic.tg_group.group_id = tic.user_group.group_id
	AND tic.tg_group.group_name='admin';

--I enter into Tickets-managers the tickets users who have an ioe email and are 'logger' but not 'admin'
INSERT INTO rm.groups_users
	SELECT groups.id, people.id
	FROM rm.users as groups, rm.users as people, tic.tg_user, tic.tg_group, tic.user_group
	WHERE groups.lastname = 'Tickets-managers'
	AND people.mail LIKE '%@ioe%'
	AND people.mail = tic.tg_user.email_address
	AND tic.tg_user.user_id = tic.user_group.user_id
	AND tic.tg_group.group_id = tic.user_group.group_id
	GROUP BY people.id
	HAVING GROUP_CONCAT(tic.tg_group.group_name) LIKE '%logger%'
	AND GROUP_CONCAT(tic.tg_group.group_name) NOT LIKE '%admin%';
	
--I enter into Tickets-fixers the tickets users who have an ioe email and are 'fixer' but not 'logger'
INSERT INTO rm.groups_users
	SELECT groups.id, people.id
	FROM rm.users as groups, rm.users as people, tic.tg_user, tic.tg_group, tic.user_group
	WHERE groups.lastname = 'Tickets-fixers'
	AND people.mail LIKE '%@ioe%'
	AND people.mail = tic.tg_user.email_address
	AND tic.tg_user.user_id = tic.user_group.user_id
	AND tic.tg_group.group_id = tic.user_group.group_id
	GROUP BY people.id
	HAVING GROUP_CONCAT(tic.tg_group.group_name) LIKE '%assignee%'
	AND GROUP_CONCAT(tic.tg_group.group_name) NOT LIKE '%logger%';
	
--create a temporary mapping table 'old id to new id' for easier job migration
--nb: there is only one old user with no email
CREATE TEMP TABLE people_mapping ( tickets_id integer, redmine_id integer);
INSERT INTO people_mapping SELECT tic.tg_user.user_id, rm.users.id
	FROM tic.tg_user, rm.users
	WHERE tic.tg_user.email_address = rm.users.mail
	OR (tic.tg_user.user_name like 'Name not%' and rm.users.firstname = 'Name');

----people as members of projects with a role
--the groups tickets-admin and tickets-managers and their people become members of the 'Tickets' project with role 'Manager'
--all the other projects inherit the same, but seem to need to be entered in the database explicitely
--create the members for all projects
INSERT INTO rm.members (user_id, project_id)
	SELECT rm.users.id, rm.projects.id
	FROM rm.users, rm.projects
	WHERE rm.users.type = 'Group'
	AND (rm.users.lastname = 'Tickets-managers' OR rm.users.lastname = 'Tickets-admin');

INSERT INTO rm.members (user_id, project_id)
	SELECT rmu.id, rm.projects.id
	FROM rm.users as rmg, rm.users as rmu, rm.projects, rm.groups_users
	WHERE rmu.type = 'User'
	AND rmg.type = 'Group'
	AND (rmg.lastname = 'Tickets-managers' OR rmg.lastname = 'Tickets-admin')
	AND rmg.id = rm.groups_users.group_id
	AND rmu.id = rm.groups_users.user_id;

--for the role the inherited_from field shows inheritance through user groups then through the project hierarchy
--groups into tickets project
INSERT INTO rm.member_roles (member_id, role_id)
	SELECT rm.members.id, rm.roles.id
	FROM rm.members, rm.roles, rm.users, rm.projects
	WHERE rm.roles.name = 'Manager'
	AND rm.members.user_id = rm.users.id
	AND rm.users.type = 'Group'
	AND rm.members.project_id = rm.projects.id
	AND rm.projects.name = 'Tickets';

----do temp table to make things more explicit
CREATE TEMP TABLE project_people (user_id integer, user_type VARCHAR(255), group_id integer, project_id integer, project_name VARCHAR(255), parent_project_id integer, member_id integer);
--groups
--there is no group_id, we have a flat hierarchy, groups don't belong to other groups
INSERT INTO project_people (user_id, user_type, project_id, project_name, parent_project_id, member_id)
	SELECT  rm.members.user_id, 'Group', rm.members.project_id, rm.projects.name, rm.projects.parent_id, rm.members.id
	FROM rm.members, rm.users, rm.projects
	WHERE rm.members.user_id = rm.users.id
	AND rm.users.type = 'Group'
	AND rm.members.project_id = rm.projects.id;
--people
--group_id is the users.id of the group the person belongs to
INSERT INTO project_people (user_id, user_type, group_id, project_id, project_name, parent_project_id, member_id)
	SELECT  rm.members.user_id, 'User', rm.groups_users.group_id, rm.members.project_id, rm.projects.name, rm.projects.parent_id, rm.members.id
	FROM rm.members, rm.groups_users, rm.projects
	WHERE rm.members.user_id = rm.groups_users.user_id
	AND rm.members.project_id = rm.projects.id;

--SELECT count(*) FROM project_people;

--groups' people into the tickets, ie the members from the tickets project which are not group
INSERT INTO rm.member_roles (member_id, role_id, inherited_from)
	SELECT upp.member_id, rm.roles.id, rm.member_roles.id
	FROM project_people as upp, project_people as gpp, rm.roles, rm.member_roles
	WHERE rm.roles.name = 'Manager'
	AND rm.member_roles.inherited_from IS NULL
	AND upp.group_id = gpp.user_id
	AND gpp.member_id = rm.member_roles.member_id
	AND upp.project_name = 'Tickets';

--tickets managers into first level sub-projects
INSERT INTO rm.member_roles (member_id, role_id, inherited_from)
	SELECT cpp.member_id, rm.roles.id, rm.member_roles.id
	FROM project_people as cpp, project_people as ppp, rm.roles, rm.member_roles
	WHERE rm.roles.name = 'Manager'
	AND cpp.parent_project_id = ppp.project_id
	AND ppp.project_name = 'Tickets'
	AND ppp.member_id = rm.member_roles.member_id
	AND cpp.user_id = ppp.user_id;
	
--tickets managers into second-level sub-projects
--nb:if != 'Tickets' is true it means it is not null either
INSERT INTO rm.member_roles (member_id, role_id, inherited_from)
	SELECT cpp.member_id, rm.roles.id, rm.member_roles.id
	FROM project_people as cpp, project_people as ppp, rm.roles, rm.member_roles
	WHERE rm.roles.name = 'Manager'
	AND cpp.parent_project_id = ppp.project_id
	AND ppp.project_name != 'Tickets'
	AND ppp.member_id = rm.member_roles.member_id
	AND cpp.user_id = ppp.user_id;


----job to issue
INSERT INTO rm.issues (tracker_id, project_id, subject, description, status_id, priority_id, author_id, created_on, updated_on, start_date)
    SELECT rm.trackers.id, sweep_mapping.redmine_id, tic.job.topic, tic.job.description, status_mapping.redmine_id, priority_mapping.redmine_id, people_mapping.redmine_id, datetime('now'), datetime('now'), tic.job.created
    FROM tic.query_type, tic.job, rm.trackers, sweep_mapping, status_mapping, priority_mapping, people_mapping
    WHERE tic.job.query_type_id = tic.query_type.id
    AND tic.query_type.name = rm.trackers.name
    AND tic.job.sweep_id = sweep_mapping.tickets_id
    AND tic.job.status_id = status_mapping.tickets_id
    AND tic.job.severity_id = priority_mapping.tickets_id
    AND tic.job.logger_id = people_mapping.tickets_id;

--add lft and rgt values to issues
--I assume that the issues are not nested
UPDATE rm.issues SET lft = id * 2 - 1, rgt = id * 2;

