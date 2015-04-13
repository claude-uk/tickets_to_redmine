--migrator.sql
--migrates the tickets database to the redmine database
--usage: sqlite3 < migrator.sql
--claude gierl
--version01 27.02.15

attach database 'tickets.db' as 'tic';
attach database 'redmine.sqlite3' as 'rm';

----system level options 

----query_type to tracker
--keep the default redmine items 'Bug','Feature', 'Support'
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
INSERT INTO rm.issue_statuses (name, is_closed) values ('Allocated', 'f');
INSERT INTO rm.issue_statuses (name, is_closed) values ('Unresolved', 't');
--to do: edit workflow

--create a temporary mapping table 'old id to new id' for easier job migration
CREATE TEMP TABLE status_mapping ( tickets_id integer, redmine_id integer);
INSERT INTO status_mapping SELECT tic.status.id, rm.issue_statuses.id FROM tic.status, rm.issue_statuses WHERE tic.status.name = 'Logged' AND rm.issue_statuses.name = 'New';
INSERT INTO status_mapping SELECT tic.status.id, rm.issue_statuses.id FROM tic.status, rm.issue_statuses WHERE tic.status.name = 'Allocated' AND rm.issue_statuses.name = 'Allocated';
INSERT INTO status_mapping SELECT tic.status.id, rm.issue_statuses.id FROM tic.status, rm.issue_statuses WHERE tic.status.name = 'In Progress' AND rm.issue_statuses.name = 'In Progress';
INSERT INTO status_mapping SELECT tic.status.id, rm.issue_statuses.id FROM tic.status, rm.issue_statuses WHERE tic.status.name = 'Awaiting Info' AND rm.issue_statuses.name = 'Feedback';
INSERT INTO status_mapping SELECT tic.status.id, rm.issue_statuses.id FROM tic.status, rm.issue_statuses WHERE tic.status.name =  'Cancelled' AND rm.issue_statuses.name = 'Rejected';
INSERT INTO status_mapping SELECT tic.status.id, rm.issue_statuses.id FROM tic.status, rm.issue_statuses WHERE tic.status.name = 'Resolved' AND rm.issue_statuses.name = 'Resolved';
INSERT INTO status_mapping SELECT tic.status.id, rm.issue_statuses.id FROM tic.status, rm.issue_statuses WHERE tic.status.name = 'Unresolved' AND rm.issue_statuses.name = 'Unresolved';

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
--The projects use a 'nested set' structure.
--to do: rigth and left values, projects don't display without it
INSERT INTO rm.projects (name, identifier) values ("Tickets", "Tickets");
INSERT INTO rm.projects (name, identifier, parent_id)
	SELECT tic.survey.name, tic.survey.name, rm.projects.id
	FROM tic.survey, rm.projects
	WHERE rm.projects.name = "Tickets";
INSERT INTO rm.projects (name, identifier, parent_id)
	SELECT tic.sweep.name, tic.sweep.name, rm.projects.id
	FROM tic.sweep, tic.survey, rm.projects
	WHERE tic.sweep.survey_id = tic.survey.id
	AND tic.survey.name = rm.projects.name
	AND tic.sweep.name != "n/a";

--create a temporary mapping table 'old id to new id' for easier job migration
CREATE TEMP TABLE sweep_mapping ( tickets_id integer, redmine_id integer);
INSERT INTO sweep_mapping SELECT tic.sweep.id, rm.projects.id
	FROM tic.sweep, rm.projects
	WHERE tic.sweep.name = rm.projects.name;
	
----job to issue
--INSERT INTO rm.issues (tracker_id, project_id, subject, description, status_id, priority_id)
--    SELECT tracker.id, sweep_mapping.redmine_id, job.topic, job.description, status_mapping.redmine_id, priority_mapping.redmine_id
--    FROM tic.query_type, tic.job, rm.tracker, sweep_mapping, issue_mapping, priority_mapping
--    WHERE tic.job.query_type_id = tic.query_type.id
--    AND tic.query_type.name = rm.tracker.name
--    AND tic.job.sweep_id = sweep_mapping.tickets_id
--    AND tic.job.status_id = status_mapping.tickets_id
--    AND tic.job.severity_id = priority_mapping.tickets_id;

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
--I assume that users get the permissions of the most powerful they belong to or that they can move to a new group
INSERT INTO rm.users (lastname, type) values ('Tickets-clients-ext', 'Group');
INSERT INTO rm.users (lastname, type) values ('Tickets-clients-ioe', 'Group');
INSERT INTO rm.users (lastname, type) values ('Tickets-fixers', 'Group');
INSERT INTO rm.users (lastname, type) values ('Tickets-managers', 'Group');
INSERT INTO rm.users (lastname, type) values ('Tickets-admin', 'Group');
--I put the first part of the tickets display name into first name, the rest into surname, to be cleaned up manually.
--for the lastname I left trim anything but space (alpha, hyphen or dash) then trim again for spaces
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
INSERT INTO rm.groups_users
	SELECT groups.id, people.id
	FROM rm.users as groups, rm.users as people
	WHERE groups.lastname = 'Tickets-clients-ext'
	AND people.mail NOT LIKE '%@ioe%'
	AND people.type = 'User';

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
	WHERE groups.lastname = 'Tickets-clients-ioe'
	AND people.mail LIKE '%@ioe%'
	AND people.mail = tic.tg_user.email_address
	AND tic.tg_user.user_id = tic.user_group.user_id
	AND tic.tg_group.group_id = tic.user_group.group_id
	AND tic.tg_group.group_name='admin';

--I enter into Tickets-managers the tickets users who have an ioe email and are 'logger' but not 'admin'
INSERT INTO rm.groups_users
	SELECT groups.id, people.id
	FROM rm.users as groups, rm.users as people, tic.tg_user, tic.tg_group, tic.user_group
	WHERE groups.lastname = 'Tickets-clients-ioe'
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
	WHERE groups.lastname = 'Tickets-clients-ioe'
	AND people.mail LIKE '%@ioe%'
	AND people.mail = tic.tg_user.email_address
	AND tic.tg_user.user_id = tic.user_group.user_id
	AND tic.tg_group.group_id = tic.user_group.group_id
	GROUP BY people.id
	HAVING GROUP_CONCAT(tic.tg_group.group_name) LIKE '%assignee%'
	AND GROUP_CONCAT(tic.tg_group.group_name) NOT LIKE '%logger%';
	
