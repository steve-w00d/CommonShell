#!/usr/bin/perl -w

# $Id: ldapadmin.pl,v 1.8 2012/05/23 16:40:50 dannyc Exp dannyc $
# $Log: ldapadmin.pl,v $
#
# Revision 1.9.5 2012/11/17  18:50:26  michalis
# switch --action= removed - in favour of --add, --check, --delete, --modify, --list
#
# Revision 1.9 2012/11/06  15:46:26  michalis
# implemented modify_user functionality - added modify: uid/uidNumber/
#
# Revision 1.8  2012/05/23 16:40:50  dannyc
# add del sudo commands
#
# Revision 1.7  2012/05/23 14:26:09  dannyc
# updated sudo  checks and user lockout
#
# Revision 1.6  2012/05/22 22:00:48  dannyc
# uses printf for showusers and showgroups
# finished implementation of delete and purge users
#

#####################################
# This file is being managed by RCS #
#####################################

# list of modules to use
use v5.10;
use strict;
use Getopt::Long;
use Net::LDAP;
use Data::Dumper;
use Net::LDAP::Util qw(ldap_error_text);
use Pod::Usage;
use Net::SSH::AuthorizedKeysFile;

#use Net::LDAP::Entry; <--- sucks as can not `use strict`!!!

# minumum perl version 5.10
# as we are using the routine when/given
require v5.10;

####################
# global variables #
####################

# default user variables
# change the variables in ldapadmin.cfg
my $binddn        = "cn=Manager,dc=example,dc=com";
my $bindpw        = "password";
my $base          = "dc=example,dc=com";
my $ou_users      = "ou=people";
my $ou_groups     = "ou=groups";
my $ou_sudoers    = "ou=SUDOers";
my $hostname      = "localhost";
my $port          = "389";
my $show_password = "no";
my $default_shell = "bash";
my $uri           = 'ldapi://';

# the default system group to put users into.
# this group does not exist in ldap!
my $standard_group = "users";
my $standard_gid   = 100;

# hard limit user assigned id minimum
# soft limit auto assigned id minimum
my $minimum_uid_hard = 1000;
my $minimum_uid_soft = 2000;
my $minimum_gid_hard = 1000;
my $minimum_gid_soft = 2000;

# Auto commit delete?
my $auto_commit = "no";

### Do not change anything below here!!!

# internal variables
my $config_file = "ldapadmin.cfg";
my @config_locations =
  ( "/usr/local/etc", "/etc", "/usr/local/accesscontrol/etc" );

my $ldap;
my $program       = "ldapadmin";
my $version       = "1.9.5";
my $message_level = 4;
my $self          = &get_me;

# prevent creating the following groups in ldap
my @reserved_groups = (
    "adm",           "apache",    "audio",     "avahi",
    "avahi-autoipd", "bin",       "cacti",     "daemon",
    "dbus",          "dip",       "disk",      "ecryptfs",
    "exim",          "floppy",    "ftp",       "games",
    "gopher",        "haldaemon", "jboss",     "kmem",
    "lock",          "lp",        "mail",      "mailnull",
    "man",           "mem",       "mysql",     "named",
    "news",          "nfsnobody", "nobody",    "nscd",
    "ntp",           "pcap",      "puppet",    "root",
    "rpc",           "rpcuser",   "rrdcached", "screen",
    "slocate",       "smmsp",     "splunk",    "sshd",
    "sys",           "tomcat",    "tty",       "users",
    "utempter",      "utmp",      "uucp",      "vcsa",
    "wheel",         "xfs",       "zabbix"
);

# prevent creating the following users in ldap
my @reserved_users = (
    "adm",     "apache",    "avahi",     "avahi-autoipd",
    "bin",     "cacti",     "coremedia", "daemon",
    "dbus",    "exim",      "ftp",       "games",
    "gopher",  "haldaemon", "halt",      "jboss",
    "lp",      "mail",      "mailnull",  "mysql",
    "named",   "news",      "nfsnobody", "nobody",
    "nscd",    "ntp",       "operator",  "pcap",
    "puppet",  "reports",   "root",      "rpc",
    "rpcuser", "rrdcached", "shutdown",  "smmsp",
    "splunk",  "sshd",      "svn",       "sync",
    "tomcat",  "uucp",      "vcsa",      "xfs",
    "zabbix"
);

# list of shells which users can use, and there locations
my %shells = (
    bash    => "/bin/bash",
    csh     => "/bin/csh",
    ksh     => "/bin/ksh",
    sh      => "/bin/sh",
    nologin => "/sbin/nologin"
);

# as standard group is not in LDAP we need to manually put this in the array.
my @sudo_groups = ("%${standard_group}");

## command line switches
my $action_add;             # --add=<s>     || -a=<s>
my $action_check;           # --check=<s>   || -c=<s>
my $action_delete;          # --delete=<s>  || -d=<s>
my $action_modify;          # --modify=<s>  || -m=<s>
my $action_list;            # --list=<s>    || -l=<s>

my $input_user;             # --user=<s>
my $input_rename_to;        # --renameto=<s>

my $input_uid;              # --uid=<i>
my $input_group;            # --group=<s>
my $input_gid;              # --gid=<i>
my $input_passwd;           # --password=<s>
my $input_shell;            # --shell=<s>
my $input_description;      # --description="<s>" || --comment="<s>"
my $input_homedir;          # --homedir=<s>
my $input_default_gid;      # --defaultgid=<i>
my $input_ssh_key_file;     # --sshfile=<s>
my $input_ssh_key;          # --sshkey=<i>
my $input_sudo_role;        # --sudorole=<s>
my $input_sudo_command;     # --sudocmd="<s>"
my $output;                 # --output=csv
my $output_filename;        # --outputfile=<s>

my $log_level;              # --loglevel=<i>
my $debug;                  # --debug
my $devdebug;               # --devdebug || -dd

my $help;                   # --help || -h
my $man;                    # --man || --doc
my $show_version;           # --version || -v
my $commit;                 # --commit
my $input_config;           # --config=<s>
my @opt_options = ();       # --option=KEY=VALUE || -o=KEY=VALUE

# display mini help if no arguments given
pod2usage( -exitval => 2, -input => $0 ) if ( ( @ARGV == 0 ) && ( -t STDIN ) );

Getopt::Long::GetOptions(
    "help|h"                => \$help,
    "man|perldoc|doc"       => \$man,
    "user|u=s"              => \$input_user,
    "renameto=s"            => \$input_rename_to,
    "uid=i"                 => \$input_uid,
    "group=s"               => \$input_group,
    "gid=i"                 => \$input_gid,
    "password=s"            => \$input_passwd,
    "shell=s"               => \$input_shell,
    "description|comment=s" => \$input_description,
    "homedir=s"             => \$input_homedir,
    "defaultgid=i"          => \$input_default_gid,
    "sshfile=s"             => \$input_ssh_key_file,
    "sshkey=i"              => \$input_ssh_key,
    "sudorole=s"            => \$input_sudo_role,
    "sudocmd=s"             => \$input_sudo_command,
    "loglevel=i"            => \$log_level,
    "debug"                 => \$debug,
    "devdebug|dd"           => \$devdebug,
    "version"               => \$show_version,
    "commit"                => \$commit,
    "config=s"              => \$input_config,

    "add|a=s"               => \$action_add,
    "check|c=s"             => \$action_check,
    "delete|d=s"            => \$action_delete,
    "modify|m=s"            => \$action_modify,
    "list|l=s"              => \$action_list,
    "o|option=s"            => sub { push @opt_options, $_[1] }
);

##################################
# Get the name of the script     #
# running without the directory. #
##################################
sub get_me {
    my @bits = split( "\/", $0 );
    my $count = @bits;
    $count--;
    return $bits[$count];
}

# de(value):
# Return 1 if value defined and is non-zero, 0 otherwise.
sub de($) {
  my ($value) = @_;
  return defined $value && $value ? 1 : 0;
}

####################################
# output script messages to screen #
####################################
sub return_message {
    my $level   = shift;
    my $message = shift;
    my $now     = localtime;
    my %test_level = ( 
        DEV     => 1, DEBUG => 2,  INFO => 3, 
        SUCCESS => 4, WARN  => 5, ERROR => 6, 
        FATAL   => 7  
        );
    if ( $message_level <= $test_level{$level} ) { print "$now $level $message\n"; }
    if ( $level eq "FATAL" ) { exit(1); }
}

###########################
# show command line usage # In Progress!!
###########################
sub usage {
    print <<_END_;
LDAP Access Control Version ${version}

Usage: ${self} [ACTION] [OPTION...]
First option must be a mode specifier:

Actions:
     -a, --add               add    ["user", "group", "sshkey", "sudorole", "sudocmd", "groupuser"]
     -c, --check             check  ["user", "group", "sshkey", "sudorole", "sudocmd", "uid", "name"]
     -d, --delete            delete ["user", "group", "sshkey", "sudorole", "sudocmd", "groupuser", "purgeuser", "purgeusers", "rmuser"]
     -m, --modify            modify ["user", "group", "sudorole"]
     -l, --list              list   ["user", "group", "users", "groups", "sshkeys", "disabledusers", "userstatus"]
     -h, --help              display this help and exit
         --man               display man page
         --debug             increase verbosity level by one
         --loglevel=<LEVEL>  level is between 1-6, 1 being debug
         --version           output version information and exit

Common Options:
     --user=<USER>           login user name
     --comment="COMMENT"     GECOS field of the new account
     --homedir=HOME_DIR      home directory of new account
     --gid=<GID>             id of the primary group of the new account
     --renameto=<USER/GROUP> rename field, used when you need to rename a user or group
     --group=<GROUP>         name of the group
     --gid=<GID>             id of the group
     --sudorole=<ROLE>       SUDO role (USER or GROUP)
     --sudocmd=<COMMAND>     commands which users can run using sudo
     --config=<FILE>         config file

Examples:

Add Actions
  Add user:                 ${self} -a user --user=<s> --comment=<s> [ --uid=<i> --homedir=<s> --shell=<s> --defaultgid=<i> --password=<s> ]
  Add user to a group:      ${self} -a groupuser --user=<s> --group=<s>
  Add group:                ${self} -a group --group=<s> [ --gid=<i> ]
  Add SSH key:              ${self} -a sshkey --user=<s> --sshfile=<s>
  Add SUDO role:            ${self} -a sudorole --sudorole=<s>
  Add SUDO command to role: ${self} -a sudocmd --sudorole=<s> --sudocmd=<s>

Check Actions 
  Check user:               ${self} -c user --user=<s> [ --uid=<i> ]
  Check group:              ${self} -c group --user=<s> [ --gid=<i> ]
  Check SSH key:            ${self} -c sshkey --user=<s> --sshfile=<s>
  Check SUDO role:          ${self} -c sudorole --sudorole=<s>
  Check SUDO command exist: ${self} -c sudocmd --sudorole=<s> --sudocmd=<s>
  
Delete Actions
  Delete user:              ${self} -d user --user=<s> [ --commit ]
  Delete user from group:   ${self} -d user --user=<s> --group=<s>
  Purge User(s):            ${self} -d purgeuser(s) --user=<s> [ --commit ]
  Delete a group:           ${self} -d group --group=<s> [ --commit ]
  Delete SSH key:           ${self} -d sshkey --user=<s> --sshkey=<i> or --sshfile=<s>
  Delete SUDO role:         ${self} -d sudorole --sudorole=<s> [ --commit ]
  Delete SUDO command:      ${self} -d sudocmd --sudorole=<s> --sudocmd=<s>

Modify Actions
  Modify user:              ${self} -m user --user=<i> [ --renameto=<s> --uid=<s> --description=<s> --homedir=<i> --shell=<s> ]
  Modify group:             ${self} -m group --group=<i> [--renameto=<s> --gid=<s> ]

List Actions
  List user(s):             ${self} -l user(s) [ --user=<s> --user=<i> --uid=<s> ]
  List group(s):            ${self} -l group(s) [ --gid=<i> ]
  List user's SSH keys:     ${self} -l sshkeys --user=<s>
_END_
    exit;

}

############
# Add user #
############
sub add_user {

    # add_user(%hash);
    # this will add a posixAccount into LDAP
    # Groups, SSH Keys, SUDOers is dealt with in other actions!
    # $params{"user"}*          what do you want to be called today?
    # $params{"uid"}            only need to override auto assigned uids
    #                           !! danger will robinson !!
    # $params{"gid"}            only if you do not want to use the default group
    # $params{"description"}*   will go to description, cn, sn
    # $params{"home"}           only needed if not set to /home/<user>
    # $params{"shell"}          bash, sh, csh, ksh, nologin
    # $params{"pass"}           crypt md5 password
    # * required to create a user.

    my ($params) = @_;
    &return_message( "DEV", "\$params:\n" . Dumper($params) . "\n" );

    my $auto = 0;

    # check that the group name is not reserved

    if ( grep /^$params->{user}$/, @reserved_users ) {
        &return_message( "WARN",
            "$params->{user} is reserved please choose a different user name" );
        return 1;
    }

    # check if we are going to auto assign a uid
    if ( !$params->{uid} ) {
        &return_message( "DEBUG", "Finding next avaliable uid" );
        $auto++;

        # we need to find an avaliable gid in LDAP
        # - get all gids from ldap
        # - sort gids
        # - highest gid +1;
        # we could reduce the server load, by creating a ldap entry
        # to track highest gid, but any manual entry would not get tracked.
        my $uids = $ldap->search(
            base   => "${ou_users},${base}",
            filter => "(&(objectClass=posixAccount))",
            scope  => "one"
        );
        if ( $uids->code ) {
            &return_message( "FATAL",
                "An error occurred binding to the LDAP server: "
                  . ldap_error_text( $uids->code ) );
        }
        my @ruids;
        if ( $uids->count > 0 ) {
            &return_message( "DEV", "uids return: $uids->count" );
            foreach my $ruid ( $uids->all_entries ) {
                push @ruids, $ruid->get_value('uidNumber');
            }

            # sort the gids
            @ruids = sort { $b <=> $a } @ruids;
            $params->{uid} = $ruids[0];
            $params->{uid}++;
        }
        else {

            # no gids found in LDAP
            # setting the gid to the minimum soft limit
            $params->{uid} = $minimum_uid_soft;
        }
        if ( !$params->{uid} ) { &return_message( "FATAL", "uid is not set" ); }
        &return_message( "DEBUG", "we have been give the uid $params->{uid}" );
    }
    else {
        my $result = &get_id_name( $ou_users, "uid", $params->{user} );

        if ( $result eq $params->{uid} ) {
            &return_message( "INFO",
                "$params->{user}:$params->{uid} already exists" );
            return 2;
        }
        if ($result) {
            &return_message( "WARN",
                "$params->{user} is already taken by ${result}" );
            return 1;
        }
        &return_message( "DEBUG", "$params->{uid} is avaliable" );
    }

    &return_message( "DEBUG", "Using uid=$params->{uid}" );

    if ( !$params->{user} ) {
        &return_message( "WARN", "What happened to the user, they went missing :O" );
        return 1;
    }

    # check is the user is avaliable
    my $result = &get_id_name( $ou_users, "uid", $params->{user} );
    if ($result) {
        &return_message( "WARN",
            "$params->{user} is already taken by uid:${result}" );
        if ( $auto == 1 ) { return 2; }
        return 1;
    }
    &return_message( "DEBUG", "$params->{user} is avaliable" );
    if ( !$params->{description} ) {
        &return_message( "WARN", "--description not set" );
        return 1;
    }

    ## check gidNumber
    ## we will not allow gid 0
    if ( $params->{gid} ) {
        &return_message( "WARN", "I hope you know what you are doing!!" );
        &return_message( "WARN",
            "Overriding default group ${standard_gid} with $params->{gid}" );
    }
    else {
        $params->{gid} = $standard_gid;
    }
    &return_message( "INFO", "Setting gid to $params->{gid}" );
    ## check homedir
    if ( $params->{home} ) {

        # do a basic path check - start with /  and contains /A-Za-z0-9
        if ( $params->{home} !~ /^\/[\/A-Za-z0-9]*$/ ) {
            &return_message( "WARN", "Path contains non alphanumeric characters: $params->{home}" );
            return 1;
        }
        &return_message( "WARN", "Overriding home directory with $params->{home}" );
    }
    else {
        $params->{home} = "/home/$params->{user}";
    }
    &return_message( "INFO", "Setting home directory to $params->{home}" );
    ## check shell
    if ( $params->{shell} ) {
        if ( $shells{ $params->{shell} } ) {
            $params->{shell} = $shells{ $params->{shell} };
        }
        else {
            &return_message( "WARN", "shell $params->{shell} is not vaild" );
            my $shell_list;
            while ( my ( $key, $value ) = each(%shells) ) {
                $shell_list .= "$key ";
            }
            &return_message( "WARN", "vaild shells: $shell_list" );
            $params->{shell} = $shells{$default_shell};
        }
    }
    else {
        $params->{shell} = $shells{$default_shell};
    }
    &return_message( "INFO", "Setting shell to $params->{shell}" );

    ## check pass
    if ( $params->{pass} ) {
        &return_message( "WARN", "WTF: Password check needs to be written!!!!" );
    }

    &return_message( "INFO", "Adding $params->{user} to LDAP" );
    my $dn = "uid=$params->{user},${ou_users},${base}";

# sshpublickey is required, but we are adding a key later, so set it to empty :)
# pwdAttribute is set to an OID: pwdAttribute which is userPassword, but the attr name does not work on every openldap install!!!
    $result = $ldap->add(
        $dn,
        attr => [
            'cn'            => $params->{description},
            'description'   => $params->{description},
            'sn'            => $params->{description},
            'gidnumber'     => $params->{gid},
            'homedirectory' => $params->{home},
            'loginShell'    => $params->{shell},
            'uid'           => $params->{user},
            'uidNumber'     => $params->{uid},
            'pwdAttribute'  => '2.5.4.35',
            'pwdLockout'    => 'FALSE',
            'sshpublickey'  => '',
            'objectclass'   => [
                'OpenLDAPperson', 'organizationalPerson', 'top', 
                'person', 'posixAccount', 'ldapPublicKey', 'pwdPolicy'
            ]
        ]
    );
    if ( $result->code ) {
        &return_message( "FATAL",
            "An error occurred binding to the LDAP server: "
              . ldap_error_text( $result->code ) );
        print $result->error;
    }

    return 0;
}

###############
# Add a group #
###############
sub add_group {

    # this is only to create a group with no users
    # add_group($group,$gid);
    my ( $group, $gid ) = @_;
    my $result;
    my $auto = 0;

    # check that the group name is not reserved
    if ( grep /^${group}$/, @reserved_groups ) {
        &return_message( "WARN", "${group} is reserved please choose a different group name" );
        return 1;
    }

    # are we going to auto assign a gid?
    if ( !$gid ) {
        &return_message( "DEBUG", "Finding next avaliable gui" );
        $auto++;

        # we need to find an avaliable gid in LDAP
        # - get all gids from ldap
        # - sort gids
        # - highest gid +1;
        # we could reduce the server load, by creating a ldap entry
        # to track highest gid, but any manual entry would not get tracked.
        my $gids = $ldap->search(
            base   => "${ou_groups},${base}",
            filter => "(&(objectClass=posixGroup))",
            scope  => "one"
        );
        if ( $gids->code ) {
            &return_message( "FATAL",
                "An error occurred binding to the LDAP server: "
                  . ldap_error_text( $gids->code ) );
        }
        my @rgids;
        if ( $gids->count > 0 ) {
            foreach my $rgid ( $gids->all_entries ) {
                push @rgids, $rgid->get_value('gidNumber');
            }

            # sort the gids
            @rgids = sort { $b <=> $a } @rgids;
            $gid = $rgids[0];
            $gid++;
        }
        else {

            # no gids found in LDAP
            # setting the gid to the minimum soft limit
            $gid = $minimum_gid_soft;
        }
        if ( !$gid ) { &return_message( "FATAL", "gid is not set" ); }
    }
    else {

        # manually assigned gid
        # check that the gid is greater then the hard limit
        if ( $gid < $minimum_gid_hard ) {
            &return_message( "WARN",
                "please choose a gid > ${minimum_gid_hard}" );
            return 1;
        }

        # check gid is avaliable
        $result = &get_id_name( $ou_groups, "gidNumber", $gid );
        if ( $result eq $group ) {
            &return_message( "INFO", "${group}:${gid} already exists" );
            return 2;
        }
        if ($result) {
            &return_message( "WARN", "${gid} is already taken by ${result}" );
            return 1;
        }
        &return_message( "DEBUG", "${gid} is avaliable" );
    }

    # check group is avaliable
    $result = &get_id_name( $ou_groups, "cn", $group );
    if ($result) {
        &return_message( "WARN", "${group} is already taken by ${result}" );
        if ( $auto == 1 ) { return 2; }
        return 1;
    }
    &return_message( "DEBUG", "${group} is avaliable" );

    # lets go and create a group
    my $dn = "cn=${group},${ou_groups},${base}";
    &return_message( "DEBUG", "dn: $dn" );

    my $aresult = $ldap->add(
        $dn,
        attr => [
            'cn'          => $group,
            'gidnumber'   => $gid,
            'objectclass' => [ 'top', 'posixGroup' ]
        ]
    );

    if ( $aresult->code ) {
        &return_message( "FATAL",
            "An error occurred binding to the LDAP server: "
              . ldap_error_text( $aresult->code ) );
        print $aresult->error;
    }

    return 0;
}

#########################
# Add a user to a group #
#########################
sub add_group_user {
    my ( $user, $group ) = @_;

 # Check if user is being added to the default group, which is not held in LDAP!
    if ( $group eq $standard_group ) {
        &return_message( "WARN",
            "Please use --moduser to add people to the group ${standard_group}"
        );
        return 1;
    }

    # Check user exists in LDAP
    # User names will still be added to a group if they dont exist in LDAP
    # as SUDOers will use the group to check rules.
    if ( !&get_id_name( $ou_users, "uid", $user ) ) {
        &return_message( "WARN", "User ${user} does not exist in LDAP" );
    }

    # Check group exists
    if ( !&get_id_name( $ou_groups, "cn", $group ) ) {
        &return_message( "WARN", "Group ${group} does not exist" );
        return 1;
    }

    # Check if user is in the group
    my $filter = "(&(objectClass=posixGroup)(memberUid=${user}))";
    &return_message( "DEBUG", "Base: ${ou_groups},${base}" );
    &return_message( "DEBUG", "Search filter: ${filter}" );
    my $result = $ldap->search(
        base   => "${ou_groups},${base}",
        filter => "${filter}",
        scope  => "one"
    );
    if ( $result->code ) {
        &return_message( "FATAL", "An error occurred binding to the LDAP server: "
              . ldap_error_text( $result->code ) );
    }

    # populate User's group
    my @membercn;
    for my $e ($result->entries)
    {
        #$e->dump;
        &return_message( "INFO", "${user} is a member of ".$e->get_value("cn")." group" );
        push @membercn, $e->get_value("cn"); 
    }
    my %params = map { $_ => 1 } @membercn;
    
    if(exists($params{$group})) { 
        &return_message( "ERROR", "${user} already in the group ${group}" );
        return 1;
    } else {
        # Add user to the group
        &return_message( "DEBUG", "Adding ${user} to ${group}" );

        my $dn = "cn=${group},${ou_groups},${base}";
        $result =
          $ldap->modify( $dn, 'add' => [ 'memberUid' => ${user} ] );
        if ( $result->code ) {
            &return_message( "FATAL",
                "An error occurred binding to the LDAP server: "
                  . ldap_error_text( $result->code ) );
        }
        return 0;
    }

}

#########################################################
# Pre process the SSH key file to amend various options #
#########################################################
sub pre_process_ssh_key {
    # Reads $HOME/.ssh/authorized_keys by default
    my $file = shift;
    my $akf = Net::SSH::AuthorizedKeysFile->new();

    $akf->read($file);

    # Iterate over entries
    # for my $key ($akf->keys()) {
    #     print $key->as_string(), "\n";
    # }

    # Modify entries:
    for my $key ($akf->keys()) {
        $key->option("no-port-forwarding", 1);
        $key->option("no-x11-forwarding", 1);
    }
    # Save changes back to $HOME/.ssh/authorized_keys
    $akf->save() or die "Cannot save";
    return 0;   
}

######################
# Add SSH public key #
######################
sub add_ssh_public_key {
    my ( $user, $file ) = @_;
    if (!&pre_process_ssh_key ($file)) {

      my %hash           = &match_ssh_public_key( $user, $file );
      my $match_count    = @{ $hash{match} };
      my $no_match_count = @{ $hash{no_match} };

      # check if the key is blank
      my $filter = "(&(objectClass=posixAccount)(uid=${user}))";
      my $result = $ldap->search(
        base   => "${ou_users},${base}",
        filter => "${filter}",
        attrs  => ['sshPublicKey'],
        scope  => "one"
      );
      if ( $result->code ) {
        &return_message( "FATAL", "An error occurred binding to the LDAP server: "
              . ldap_error_text( $result->code ) );
      }     
      my @entry           = $result->entries;
      my @keys_ldap       = $entry[0]->get_value('sshPublicKey');
      my $empty_keys_ldap_count = @keys_ldap;
      if ( $empty_keys_ldap_count == 1 ) {
          if ( $keys_ldap[0] eq '' ) { $empty_keys_ldap_count = 0; }
      }

      #need to add the unmatched keys to LDAP
      if ( $no_match_count > 0 ) {
          my $dn = "uid=${user},${ou_users},${base}";
          my $result;
          
          if ( $empty_keys_ldap_count == 0 ) {
            $result = $ldap->modify( $dn, changes => [ 'replace' => [ 'sshPublicKey' => $hash{no_match} ] ] );
            &return_message( "INFO", "SSH Key replaced");
          } else {
            $result =  $ldap->modify( $dn, add => { 'sshPublicKey' => $hash{no_match} } );
            &return_message( "INFO", "SSH Key added");
          }

          if ( $result->code ) {
              &return_message( "FATAL","An error occurred binding to the LDAP server: "
                . ldap_error_text( $result->code ) );
          }
      } else {
          &return_message( "WARN", "Not re-adding, key already in");
      }
      return 0;
    } else { 
        return 1; 
    }
}

####################
# Add SUDO command #
####################
sub add_sudo_command {
    my $sudo_role = shift;
    my $sudo_cmd  = shift;

    # check if the role is avaliable
    if ( !&check_sudo_command( $sudo_role, $sudo_cmd ) ) {
        return 2;
    }

    # add the sudo command to LDAP
    my $dn = "cn=${sudo_role},${ou_sudoers},${base}";
    &return_message( "DEBUG", "Adding ${sudo_cmd} to ${sudo_role}" );
    my $result =
      $ldap->modify( $dn,
        changes => [ 'add' => [ 'sudoCommand' => ${sudo_cmd} ] ] );
    if ( $result->code ) {
        &return_message( "FATAL",
            "An error occurred binding to the LDAP server: "
              . ldap_error_text( $result->code ) );
    }
    return 0;
}

#################
# Add SUDO role #
#################
sub add_sudo_role {
    my $sudo_role = shift;
    if ( !&check_sudo_role($sudo_role) ) {
        return 2;
    }

    # add the role to LDAP
    my $dn = "cn=${sudo_role},${ou_sudoers},${base}";
    &return_message( "DEBUG", "dn: $dn" );

    # no commands are added at this stage
    my $result = $ldap->add(
        $dn,
        attr => [
            'cn'            => $sudo_role,
            'sudoUser'      => $sudo_role,
            'sudoHost'      => 'ALL',
            'sudoCommand'   => 'ALL',
            'sudoOption'    => '!authenticate',
            'sudoRunAsUser' => 'ALL',
            'objectclass'   => [ 'top', 'sudoRole' ]
        ]
    );

    if ( $result->code ) {
        &return_message( "FATAL",
            "An error occurred binding to the LDAP server: "
              . ldap_error_text( $result->code ) );
        print $result->error;
        return 1;
    }
    return 0;
}

#######################
# delete/purge a user #
#######################
sub delete_user {
    my ( $user, $del_action ) = @_;

    # check the user exists and there status
    my $status = &get_user_status;

    if ( $del_action eq "purge" ) {
        &return_message( "DEBUG",
            "We are removing the user from LDAP if they are disabled" );
        if ( $status eq "FALSE" ) {
            &return_message( "INFO", "${user} is not disabled in LDAP" );
            return 3;
        }
    }
    elsif ( $del_action eq "delete" ) {
        &return_message( "DEBUG",
            "We dont care we are removing the user from LDAP" );
    }
    else {
        &return_message( "FATAL", "Not delete action set" );
    }

    if ($commit) {

        # remove user from ou_groups
        &return_message( "DEBUG", "Checking which groups to remove ${user} from" );

        my $filter = "(&(objectClass=posixGroup)(memberUid=${user}))";
        &return_message( "DEBUG", "Base: ${ou_groups},${base}" );
        &return_message( "DEBUG", "Search filter: ${filter}" );
        my $result = $ldap->search(
            base   => "${ou_groups},${base}",
            filter => "${filter}",
            scope  => "one"
        );
        if ( $result->code ) {
            &return_message( "FATAL",
                "An error occurred binding to the LDAP server: "
                  . ldap_error_text( $result->code ) );
        }
        my $entries = $result->entries;

        &return_message( "DEBUG", "Results Returned: $entries" );
        if ( $entries == 0 ) {
            &return_message( "INFO", "${user} is not in any groups" );
        }
        else {
            &return_message( "DEBUG", "Removing ${user} from groups" );
            &return_message( "DEV",
                "\result->entries\n" . Dumper( $result->entries ) );
            foreach my $entry ( $result->entries ) {
                my $dn =
                  "cn=" . $entry->get_value('cn') . ",${ou_groups},${base}";
                &return_message( "DEBUG", "dn: $dn" );
                if ($commit) {
                    my $mod_result =
                      $ldap->modify( $dn,
                        changes => [ 'delete' => [ 'memberUid' => ${user} ] ] );
                    if ( $mod_result->code ) {
                        &return_message( "FATAL",
                            "An error occurred binding to the LDAP server: "
                              . ldap_error_text( $mod_result->code ) );
                    }
                    &return_message( "INFO",
                        "Removed ${user} from " . $entry->get_value('cn') );
                }
                else {
                    &return_message( "WARN",
                            "To remove ${user} from "
                          . $entry->get_value('cn')
                          . " please add the switch --commit" );
                }
            }
        }

        # remove user from ou_users
        my $dn = "uid=${user},${ou_users},${base}";
        &return_message( "DEBUG", "dn: ${dn}" );
        &return_message( "DEBUG", "deleting user ${user}" );
        $result = $ldap->delete($dn);
        if ( $result->code ) {
            &return_message( "FATAL",
                "An error occurred binding to the LDAP server: "
                  . ldap_error_text( $result->code ) );
        }
        return 0;
    }
    else {
        &return_message( "DEBUG",
            "confirm switch not set, not deleting user ${user}" );
        return 2;
    }
}

####################################
# Purge all users who are disabled #
####################################
sub purge_users {

    # get a list of all users to be purged
    &return_message( "DEBUG", "Building list of users to be purged" );
    my ( @users, $user );

    my $filter =
"(&(objectClass=posixAccount)(pwdLockout=TRUE)(loginShell=$shells{nologin}))";
    &return_message( "DEBUG", "Base: ${ou_users},${base}" );
    &return_message( "DEBUG", "Search filter: ${filter}" );
    my $result = $ldap->search(
        base   => "${ou_users},${base}",
        filter => "${filter}",
        scope  => "one"
    );
    if ( $result->code ) {
        &return_message( "FATAL",
            "An error occurred binding to the LDAP server: "
              . ldap_error_text( $result->code ) );
        print $result->error;
    }

    if ( $result->count > 0 ) {
        foreach my $entry ( $result->all_entries ) {
            push @users, $entry->get_value('uid');
            &return_message( "WARN",
                $entry->get_value('uid') . " to be purged" );
        }
    }
    else {
        return 1;
    }
    if ($commit) {
        foreach $user (@users) {

            # remove user from ou_users
            &return_message( "WARN", "Removing user ${user}" );
            &delete_user( $user, "purge" );
        }
        return 0;
    }
    else {
        &return_message( "DEBUG", "confirm switch not set, not purging users" );
        return 2;
    }
}

##########################################
# Check if a user is enabled or disabled #
##########################################
sub get_user_status {
    my ($user) = shift;

    # check the user exists
    if ( !&get_id_name( $ou_users, "uid", $user ) ) {
        &return_message( "FATAL", "User ${user} does not exist" );
        exit 1;
    }

    my $filter = "(&(objectClass=posixAccount)(uid=${user}))";

    my $searchresult = $ldap->search(
        base   => "${ou_users},${base}",
        filter => "${filter}",
        scope  => "one"
    );
    if ( $searchresult->code ) {
        &return_message( "FATAL",
            "An error occurred binding to the LDAP server: "
              . ldap_error_text( $searchresult->code ) );
    }
    my $entries = $searchresult->entries;

    &return_message( "DEBUG", "Results Returned: $entries" );

    if ( $entries == 0 ) {
        &return_message( "FATAL", "User does not exist" );
    }
    elsif ( $entries == 1 ) {
        my $entry = $searchresult->entry(0);
        &return_message( "DEV", "\$entry:\n" . Dumper($entry) );
        my $return_value = $entry->get_value('pwdLockout');
        return $return_value;
    }
}

###################################
# Enable or Disable a users login #
###################################
sub change_user_status {
    my ( $user, $status ) = @_;
    my ( $pwdLockout, $shell );
    if ( $status eq "lock" ) {
        $pwdLockout = "TRUE";

        # set the users shell to login to disable server access
        $shell = $shells{nologin};
    }
    elsif ( $status eq "unlock" ) {
        $pwdLockout = "FALSE";

        # reset the users shell to the default shell in the config
        $shell = $shells{$default_shell};
    }
    else {
        &return_message( "FATAL", "Invalid status change request $status" );
    }

    # check the user exists
    if ( !&get_id_name( $ou_users, "uid", $user ) ) {
        &return_message( "FATAL", "User ${user} does not exist" );
        exit 1;
    }

    # update the user
    my $dn     = "uid=${user},${ou_users},${base}";
    my $result = $ldap->modify( $dn,
        'replace' => [ 'pwdLockout' => ${pwdLockout}, 'loginShell' => $shell ]
    );
    if ( $result->code ) {
        &return_message( "FATAL",
            "An error occurred binding to the LDAP server: "
              . ldap_error_text( $result->code ) );
    }

    # return command completed
    return 0;
}

###################
# delete a group  #
###################
sub delete_group {

    # delete_group($group);
    my $group = shift;

    # check the group exists
    if ( &return_message( "INFO", "Group ${group} does not exist" ) ) {
        return 3;
    }

    my $dn = "cn=${group},${ou_groups},${base}";
    &return_message( "DEBUG", "dn: ${dn}" );
    if ($commit) {
        &return_message( "DEBUG", "deleting group ${group}" );
        my $result = $ldap->delete($dn);
        if ( $result->code ) {
            &return_message( "FATAL",
                "An error occurred binding to the LDAP server: "
                  . ldap_error_text( $result->code ) );
        }
        return 0;
    }
    else {
        &return_message( "DEBUG",
            "confirm switch not set, not deleting group ${group}" );
        return 2;
    }
}

##############################
# Delete a user from a group #
##############################
sub delete_group_user {
    my ( $user, $group ) = @_;

 # Check if user is being added to the default group, which is not held in LDAP!
    if ( $group eq $standard_group ) {
        &return_message( "WARN",
"Please use --moduser to delete people to the group ${standard_group}"
        );
        return 1;
    }

    # Check user exists in LDAP
    # User names will still be added to a group if they dont exist in LDAP
    # as SUDOers will use the group to check rules.
    # if ( !&get_id_name( $ou_users, "uid", $user ) ) {
    #     &return_message( "WARN", "User ${user} does not exist in LDAP" );
    # }

    # Check group exists
    if ( !&get_id_name( $ou_groups, "cn", $group ) ) {
        &return_message( "WARN", "Group ${group} does not exist" );
        return 1;
    }

    # Check if user is in the group
    my $filter = "(&(objectClass=posixGroup)(memberUid=${user}))";
    &return_message( "DEBUG", "Base: ${ou_groups},${base}" );
    &return_message( "DEBUG", "Search filter: ${filter}" );
    my $result = $ldap->search(
        base   => "${ou_groups},${base}",
        filter => "${filter}",
        scope  => "one"
    );
    if ( $result->code ) {
        &return_message( "FATAL",
            "An error occurred binding to the LDAP server: "
              . ldap_error_text( $result->code ) );
    }
    my $entries = $result->entries;

    if ( $entries == 0 ) {
        &return_message( "INFO", "${user} not in the group ${group}" );
        return 2;
    }

    # Add user to the group
    &return_message( "DEBUG", "Adding ${user} to ${group}" );

    my $dn = "cn=${group},${ou_groups},${base}";
    $result =
      $ldap->modify( $dn,
        changes => [ 'delete' => [ 'memberUid' => ${user} ] ] );
    if ( $result->code ) {
        &return_message( "FATAL",
            "An error occurred binding to the LDAP server: "
              . ldap_error_text( $result->code ) );
    }

    return 0;
}

#########################
# Delete SSH public key #
#########################
sub delete_ssh_public_key {
    my ( $user, $attribute, $value ) = @_;

    # check the user exists
    if ( !&get_id_name( $ou_users, "uid", $user ) ) {
        &return_message( "WARN", "User ${user} does not exist" );
        exit 1;
    }

    my $filter = "(&(objectClass=posixAccount)(uid=${user}))";

    # first get number of keys
    &return_message( "DEBUG", "Base: ${ou_users},${base}" );
    &return_message( "DEBUG", "Search filter: ${filter}" );
    my $result = $ldap->search(
        base   => "${ou_users},${base}",
        filter => "${filter}",
        attrs  => ['sshPublicKey'],
        scope  => "one"
    );
    if ( $result->code ) {
        &return_message( "FATAL",
            "An error occurred binding to the LDAP server: "
              . ldap_error_text( $result->code ) );
    }
    my $entries = $result->entries;
    &return_message( "DEBUG", "Results Returned: $entries" );
    &return_message( "DEV", "$result->entries\n" . Dumper( $result->entries ) );
    if ( $entries == 0 ) {
        &return_message( "DEBUG", "No results returned" );
        return 1;
    }
    elsif ( $entries == 1 ) {

        # if number of keys is 1, then just null the key
        my @entry     = $result->entries;
        my @keys      = $entry[0]->get_value('sshPublickey');
        my $key_count = @keys;
        if ( $key_count == 1 ) {
            if ( $keys[0] eq '' ) { $key_count = 0; }
        }
        &return_message( "DEBUG", "SSH key count: ${key_count}" );

        # user has no keys - bail
        if ( $key_count == 0 ) {
            &return_message( "WARN", "${user} does not have ssh keys" );
            return 0;
        }

        # check if we are doing key or file
        if ( $attribute eq "key" ) {
            my $key = $value;

            # check if request is great then ldap.
            if ( $key > $key_count ) {
                &return_message( "WARN", "Invalid key deletion request" );
                return 1;
            }

            if ( $key_count == 1 && $key == 1 ) {

                # null the ssh public key
                my $dn = "uid=${user},${ou_users},${base}";
                my $result =
                  $ldap->modify( $dn,
                    changes => [ 'replace' => [ 'sshPublicKey' => '' ] ] );
                if ( $result->code ) {
                    &return_message( "FATAL",
                        "An error occurred binding to the LDAP server: "
                          . ldap_error_text( $result->code ) );
                }
                &return_message( "DEBUG", "Removed key for ${user}." );
            }
            if ( $key_count > 1 ) {
                $key--;
                my $dn     = "uid=${user},${ou_users},${base}";
                my $result = $ldap->modify( $dn,
                    changes => [ 'delete' => [ 'sshPublicKey' => $keys[$key] ] ]
                );
                if ( $result->code ) {
                    &return_message( "FATAL",
                        "An error occurred binding to the LDAP server: "
                          . ldap_error_text( $result->code ) );
                }
                &return_message( "DEBUG", "Removed key for ${user}." );
            }
        }
        else {

            my %hash           = &match_ssh_public_key( $user, $value );
            my $match_count    = @{ $hash{match} };
            my $no_match_count = @{ $hash{no_match} };
            print "a:" . $match_count . "\n";

            if ( $key_count == $match_count ) {
                my $dn = "uid=${user},${ou_users},${base}";
                my $result =
                  $ldap->modify( $dn,
                    changes => [ 'replace' => [ 'sshPublicKey' => '' ] ] );
                if ( $result->code ) {
                    &return_message( "FATAL",
                        "An error occurred binding to the LDAP server: "
                          . ldap_error_text( $result->code ) );
                }
                &return_message( "DEBUG", "Removed keys for ${user}." );
            }
            else {
                my $dn     = "uid=${user},${ou_users},${base}";
                my $result = $ldap->modify( $dn,
                    changes =>
                      [ 'delete' => [ 'sshPublicKey' => $hash{match} ] ] );
                if ( $result->code ) {
                    &return_message( "FATAL",
                        "An error occurred binding to the LDAP server: "
                          . ldap_error_text( $result->code ) );
                }
                &return_message( "DEBUG", "Removed keys for ${user}." );
            }
        }
    }

}

#######################
# Delete SUDO command #
#######################
sub delete_sudo_command {
    my $sudo_role = shift;
    my $sudo_cmd  = shift;

    # check if the role is avaliable
    if ( &check_sudo_command( $sudo_role, $sudo_cmd ) ) {
        return 1;
    }

    # add the sudo command to LDAP
    my $dn = "cn=${sudo_role},${ou_sudoers},${base}";
    &return_message( "DEBUG", "Adding ${sudo_cmd} to ${sudo_role}" );
    my $result =
      $ldap->modify( $dn,
        changes => [ 'delete' => [ 'sudoCommand' => ${sudo_cmd} ] ] );
    if ( $result->code ) {
        &return_message( "FATAL",
            "An error occurred binding to the LDAP server: "
              . ldap_error_text( $result->code ) );
    }
    return 0;
}

####################
# Delete SUDO role #
####################
sub delete_sudo_role {
    my $sudo_role = shift;

    if ( &check_sudo_role($sudo_role) ) {
        &return_message( "FATAL", "SUDO role ${sudo_role} does not exists" );
    }

    if ($commit) {
        my $dn = "cn=${sudo_role},${ou_sudoers},${base}";
        &return_message( "DEBUG", "dn: ${dn}" );
        &return_message( "DEBUG", "deleting SUDO role: ${sudo_role}" );
        my $result = $ldap->delete($dn);
        if ( $result->code ) {
            &return_message( "FATAL",
                "An error occurred binding to the LDAP server: "
                  . ldap_error_text( $result->code ) );
        }
        return 0;
    }
    &return_message( "DEBUG",
        "confirm switch not set, not deleting SUDO role ${sudo_role}" );
    return 1;
}

################
# LDAP_replace #
################
sub LDAP_modify {
    my ($dn, $do, $replaceArray) = @_;
     &return_message( "DEV", "\$replaceArray\n" . Dumper($replaceArray) );
    my $result = $ldap->modify ( $dn, changes => [ $do => [ @$replaceArray ] ] );
    if ( $result->code ) {
        &return_message( "FATAL",
            "An error occurred binding to the LDAP server: "
            . ldap_error_text( $result->code ) );
    }
    return $result;
}

###############
# Modify User # In Progress!!
###############
sub modify_user {
    # $details->{"user"}        = $input_user;
    # $details->{"uid"}         = $input_uid;
    # $details->{"gid"}         = $input_default_gid;
    # $details->{"description"} = $input_description;
    # $details->{"home"}        = $input_homedir;
    # $details->{"shell"}       = $input_shell;
    # $details->{"pass"}        = $input_passwd;
    
    # SEC-24:
    # Attributes that need to be able to be modified with moduser action are:
    # cn, sn, description (=sn=cn), gidNumber(notPossible), homeDirectory, loginShell, User Name (uid), uidNumber

    my ( $rename_user, $params ) = @_;    
    my $skip = 0;
    my @whatToChange;
    my @ReplaceArray;
    my $dn = "uid=$params->{user},${ou_users},${base}";
    &return_message( "DEV", "\$params\n" . Dumper($params) );

    # check user exists
    #my $old_uid = &get_id_name( $ou_users, "uid", $curr_user );
    my $old_uid = &get_id_name( $ou_users, "uid", $params->{user} );
    &return_message( "DEBUG", "Old user: $params->{user}" );
    if ( !$old_uid ) {
        &return_message( "INFO", "$params->{user} does not exist" );
        return 1;
    }
    &return_message( "DEBUG", "$params->{user} exists" );

    if (de($params->{"uid"}) + 
        de($params->{"gid"}) +
        de($params->{"description"}) +
        de($params->{"home"}) +
        de($params->{"shell"}) +
        de($params->{"pass"}) == 0) {
        &return_message( "WARN", "No Action has been defined" );
        return 1;
    }

    if ( $rename_user ) {
       # check that the new user name is not reserved
        if ( grep /^${rename_user}$/, @reserved_users ) {
            &return_message( "WARN", "${rename_user} is reserved please choose a different user name" );
            return 1;
        }

        # check new user
        # if new user, then check its free
        my $new_uid = &get_id_name( $ou_users, "uid", $rename_user );
        if ($new_uid) {
            &return_message( "WARN", "${rename_user} is already taken by ${new_uid}" );
            return 1;
        }

        # if we are updating the user name    
        # now updated the user name, required to be done last as we are using `moddn`
        # does new and old user name match?
        if ( ( !$rename_user ) || ( $params->{user} eq $rename_user ) ) {
            &return_message( "DEBUG", "Not updating user name" );
            $skip++;
        } else {

            # check new user does not exist
            if ( !&get_id_name( $ou_users, "uid", $rename_user ) ) {
                # modify the user with new user name
                &return_message( "DEBUG", "Update of user name" );
                my $result =
                  $ldap->moddn( $dn, newrdn => "uid=${rename_user}", deleteoldrdn => 1 );
                if ( $result->code ) {
                    &return_message( "FATAL", "An error occurred binding to the LDAP server: "
                        . ldap_error_text( $result->code ) );
                }

                # update of user group
                &return_message( "DEBUG", "Update of user group" );
                my $filter = "(&(objectClass=posixGroup)(memberUid=$params->{user}))";
                &return_message( "DEBUG", "Base: ${ou_groups},${base}" );
                &return_message( "DEBUG", "Search filter: ${filter}" );
                my $gsearchresult = $ldap->search(
                    base   => "${ou_groups},${base}",
                    filter => "${filter}",
                    scope  => "one"
                );
                if ( $gsearchresult->code ) {
                    &return_message( "FATAL", "An error occurred binding to the LDAP server: "
                        . ldap_error_text( $gsearchresult->code ) );
                }
                my $gentries = $gsearchresult->entries;                
                &return_message( "DEBUG", "Results Returned: $gentries" );
                if ( $gentries == 0 ) {
                    &return_message( "DEBUG", "No results returned WTF!" );
                } else {
                    print "\n";
                    print "  Group\t\t\tGID\n";
                    print "  ===========================\n";
                    my $i = 1;
                    foreach my $gentry ( $gsearchresult->entries ) {
                        # prepare list of groups for sudoers check
                        #$sudo_groups[$i] = "%" . $gentry->get_value('cn');
                        print "  "
                          . $gentry->get_value('cn') . "\t\t"
                          . $gentry->get_value('gidNumber') . "\n";
                        &delete_group_user( $params->{user}, $gentry->get_value('cn') );
                        &add_group_user( $rename_user, $gentry->get_value('cn') );
                        $i++;
                    }
                    print "\n";
                } 
            }
            else {
                &return_message( "WARN", "User $params->{user} already exists" );
                return 1;
            }
        } 
      }

    if ( $params->{uid} ){
        # does new and old group name match?
        if ( ( !$params->{uid} ) || ( $params->{uid} eq $old_uid ) ) {
            &return_message( "DEBUG", "Not updating uid" );
            $skip++;
        }
        else {
            # check new uid does not exist
            # check new uid
            # if new uid, then check its free        
            if ( !&get_id_name( $ou_users, "uidNumber", $params->{uid} ) ) {
                &return_message( "DEBUG", "Update of user uid" );

                # update uid
                undef @ReplaceArray;
                @ReplaceArray = ( 'uidNumber', "$params->{uid}" );
                &LDAP_modify( $dn, 'replace', \@ReplaceArray );
            }
            else {
                &return_message( "WARN", "uid $params->{uid} already exists" );
                return 1;
            }       
        }
    }

    ## modify homedir
    if ( $params->{home} ) {
        # do a basic path check - start with /  and contains /A-Za-z0-9
        if ( $params->{home} !~ /^\/[\/A-Za-z0-9]*$/ ) {
            &return_message( "WARN",
                "Path contains non alphanumeric characters: $params->{home}" );
            return 1;
        }
        &return_message( "WARN",
            "Overriding home directory with $params->{home}" );
            
        undef @ReplaceArray;
        @ReplaceArray = ( 'homeDirectory', "$params->{home}" );
        &LDAP_modify( $dn, 'replace', \@ReplaceArray );
    }
    
    ## modify shell
    if ( $params->{shell} ) {
        if ( $shells{ $params->{shell} } ) {
            $params->{shell} = $shells{ $params->{shell} };
            &return_message( "WARN", 
                "Overriding shell with $params->{shell}" );

            undef @ReplaceArray;
            @ReplaceArray = ( 'loginShell', "$params->{shell}" );
            &LDAP_modify( $dn, 'replace', \@ReplaceArray );
        }
        else {
            &return_message( "WARN", "shell $params->{shell} is not vaild" );
            my $shell_list;
            while ( my ( $key, $value ) = each(%shells) ) {
                $shell_list .= "$key ";
            }
            &return_message( "WARN", "vaild shells: $shell_list" );
            $params->{shell} = $shells{$default_shell};
        }
    }

    ## modify description
    if ( $params->{description} ) {
        &return_message( "WARN", "Overriding sn,cn,description with $params->{description}" );
        undef @ReplaceArray;
        @ReplaceArray = ( 
            'sn', "$params->{description}",
            'cn', "$params->{description}",
            'description', "$params->{description}"
            );
        &LDAP_modify( $dn, 'replace', \@ReplaceArray );
    }
    ## modify -option=KEY=VALUE [SN, CN]
    if ( de(@opt_options) ) {
      my @valid_schema = ("sn","cn");
      foreach my $opt (@opt_options) {
        my ($var,$val) = ($opt =~ /^([^=]+)=(.*)$/);
        die "invalid value for --option: $opt\n" if !defined $val;
        #set_config_option($var, $val, '');
        if ( grep /^${var}$/, @valid_schema ) {
          &return_message( "WARN", "Overriding $var with $val" );
            undef @ReplaceArray;
            @ReplaceArray = ( "$var", "$val" );
            &LDAP_modify( $dn, 'replace', \@ReplaceArray );          
        } else {
            &return_message( "WARN", "${var} is not allowed please choose a valid schema" );
            return 1;
        }
      }
    }

    # check if we need to do any thing?
    if ( $skip == 2 ) {
        &return_message( "INFO", "No update required" );
        return 0;
    }

    return 0;
}

################
# Modify Group #
################
sub modify_group {

    # modify a group details
    # modify_group($old_group,$group,$gid);
    my ( $rename_group, $group, $gid ) = @_;
    my $skip = 0;

    # check old group exists and get the old gid
    my $old_gid = &get_id_name( $ou_groups, "cn", $group );
    &return_message( "DEBUG", "Old gid: ${old_gid}" );
    if ( !$old_gid ) {
        &return_message( "INFO", "${group} does not exist" );
        return 1;
    }
    &return_message( "DEBUG", "${group} exists" );

    # did we get passed any arguments?
    if ( !$group && !$gid ) {
        &return_message( "FATAL", "you need to use the switch --renameto=<user> with --group=<group> and/or --gid=<gid>"
        );
    }

    # does new and old group name match?
    if ( ( !$gid ) || ( $gid eq $old_gid ) ) {
        &return_message( "DEBUG", "Not updating gid name" );
        $skip++;
    } else {
        # check new gid does not exist
        if ( !&get_id_name( $ou_groups, "gidNumber", $gid ) ) {
            &return_message( "DEBUG", "Update of group gid" );

            # update gid
            my $dn = "cn=${group},${ou_groups},${base}";
            my $result =
              $ldap->modify( $dn,
                changes => [ 'replace' => [ 'gidNumber' => "${gid}" ] ] );
            if ( $result->code ) {
                &return_message( "FATAL", "An error occurred binding to the LDAP server: "
                    . ldap_error_text( $result->code ) );
            }
        } else {
            &return_message( "WARN", "gid ${gid} already exists" );
            return 1;
        }
    }

    if ( $rename_group ){
        # does new and old group name match?
        if ( ( !$group ) || ( $group eq $rename_group ) ) {
            &return_message( "DEBUG", "Not updating group name" );
            $skip++;
        } else {
            # check new group does not exist
            if ( !&get_id_name( $ou_groups, "cn", $group ) ) {
                &return_message( "DEBUG", "Update of group name" );

                my $dn = "cn=${group},${ou_groups},${base}";
                my $result =
                  $ldap->moddn( $dn, newrdn => "cn=${rename_group}", deleteoldrdn => 1 );

                if ( $result->code ) {
                    &return_message( "FATAL", "An error occurred binding to the LDAP server: "
                        . ldap_error_text( $result->code ) );
                }
            }
            else {
                &return_message( "WARN", "gid ${gid} already exists" );
                return 1;
            }
        }
    }

    # check if we need to do any thing?
    if ( $skip == 2 ) {
        &return_message( "INFO", "No update required" );
        return 0;
    }

    return 0;
}

####################
# Modify SUDO role # In Progress!!
####################
sub modify_sudo_role {
    my $old_sudo_role = shift;
    return 1;
}

##############################
# show a user and its users  #
##############################
sub show_user {

    # show_user($attribute,$value);
    my ( $attribute, $value ) = @_;

    if ( !&get_id_name( $ou_users, $attribute, $value ) ) {
        &return_message( "WARN", "User ${value} does not exist" );
        exit 1;
    }

    my $filter = "(&(objectClass=posixAccount)(${attribute}=${value}))";

    &return_message( "DEBUG", "Base: ${ou_users},${base}" );
    &return_message( "DEBUG", "Search filter: ${filter}" );
    my $searchresult = $ldap->search(
        base   => "${ou_users},${base}",
        filter => "${filter}",
        scope  => "one"
    );
    if ( $searchresult->code ) {
        &return_message( "FATAL",
            "An error occurred binding to the LDAP server: "
              . ldap_error_text( $searchresult->code ) );
    }
    my $entries = $searchresult->entries;

    &return_message( "DEBUG", "Results Returned: $entries" );
    if ( $entries == 0 ) {
        &return_message( "DEBUG", "No results returned" );
        return 1;
    } elsif ( $entries == 1 ) {
        my (
            $uid,         $uidNumber,     $gidNumber,
            $description, $homeDirectory, $loginShell,
            $key_count,   @keys,          $password
        );
        my @entry = $searchresult->entries;
        &return_message( "DEBUG", "Matched: " . $entry[0]->dn );
        &return_message( "DEV",   "\@entry:\n" . Dumper(@entry) );

        # show user details
        $uid           = $entry[0]->get_value('uid');
        $uidNumber     = $entry[0]->get_value('uidNumber');
        $gidNumber     = $entry[0]->get_value('gidNumber');
        $description   = $entry[0]->get_value('description');
        $homeDirectory = $entry[0]->get_value('homeDirectory');
        $loginShell    = $entry[0]->get_value('loginShell');
        $password      = $entry[0]->get_value('userPassword');

        if ($password) {
            if ( $show_password ne 'yes' ) {
                $password = "yes";
            }
        }
        else {
            $password = "not set";
        }
        @keys      = $entry[0]->get_value('sshPublickey');
        $key_count = @keys;

        # frig the count if the key is empty.
        if ( $key_count == 1 ) {
            if ( $keys[0] eq '' ) { $key_count = 0; }
        }

        # print Dumper($entry[0]);

        print "\n";
        print "  User Details\n";
        print "  ============\n\n";
        print "  User Name:      ${uid}\n";
        print "  Description:    ${description}\n";
        print "  uid:            ${uidNumber}\n";
        print "  gid:            ${gidNumber}\n";
        print "  Login Shell     ${loginShell}\n";
        print "  Home Directory: ${homeDirectory}\n";
        print "  SSH keys:       $key_count\n";
        print "  Password:       $password\n";
        print "\n";

        #my @values = $entry[0]->attributes ( nooptions => 1 );
        #print "nooptions: @values\n";

        # show groups user is in

        my $filter = "(&(objectClass=posixGroup)(memberUid=${uid}))";
        &return_message( "DEBUG", "Base: ${ou_groups},${base}" );
        &return_message( "DEBUG", "Search filter: ${filter}" );
        my $gsearchresult = $ldap->search(
            base   => "${ou_groups},${base}",
            filter => "${filter}",
            scope  => "one"
        );
        if ( $gsearchresult->code ) {
            &return_message( "FATAL",
                "An error occurred binding to the LDAP server: "
                  . ldap_error_text( $gsearchresult->code ) );
        }
        my $gentries = $gsearchresult->entries;

        &return_message( "DEBUG", "Results Returned: $gentries" );
        if ( $gentries == 0 ) {
            &return_message( "DEBUG", "No results returned WTF!" );
            return 1;
        } else {
            print "\n";
            print "  Group\t\t\tGID\n";
            print "  ===========================\n";
            my $i = 1;
            foreach my $gentry ( $gsearchresult->entries ) {

                # prepare list of groups for sudoers check
                $sudo_groups[$i] = "%" . $gentry->get_value('cn');
                print "  "
                  . $gentry->get_value('cn') . "\t\t"
                  . $gentry->get_value('gidNumber') . "\n";
                $i++;
            }
            print "\n";
        }
        # show which sudo groups the user is in
        my $gcount = @sudo_groups;
        if ( $gcount > 0 ) {
            $filter = "(&(objectClass=sudoRole)(|";
            for ( my $i = 0 ; $i < $gcount ; $i++ ) {
                $filter .= "(cn=${sudo_groups[$i]})";
            }
            $filter .= "))";
        } else {
            &return_message( "FATAL",
                "User does not belong to any groups WTF!" );
        }
        &return_message( "DEBUG", "Base: ${ou_sudoers},${base}" );
        &return_message( "DEBUG", "Search filter: ${filter}" );
        my $ssearchresult = $ldap->search(
            base   => "${ou_sudoers},${base}",
            filter => "${filter}",
            scope  => "one"
        );
        if ( $ssearchresult->code ) {
            &return_message( "FATAL",
                "An error occurred binding to the LDAP server: "
                  . ldap_error_text( $ssearchresult->code ) );
        }
        my $sentries = $ssearchresult->entries;

        &return_message( "DEBUG", "Results Returned: $gentries" );
        print "\n";
        print "  Sudo Groups\n";
        print "  ===========\n\n";
        if ( $sentries == 0 ) {
            print "  $uid does not belong to any sudoers groups\n\n";
            &return_message( "DEBUG", "No results returned WTF!" );
            return 0;        
        } else {
            foreach my $sentry ( $ssearchresult->entries ) {
                print "  " . $sentry->get_value('cn') . "\n";
            }
            print "\n";
        }

        return 0;
    }
    elsif ( $entries > 1 ) {
        &return_message( "FATAL",
"More then one result returned for ${filter}, please fix ${ou_users}"
        );
    } else {
        &return_message( "FATAL", "Failed checking: ${filter}" );
    }

}

###################
# show all users  #
###################
sub show_users {
    my $disabled = shift;
    my ( @users, $filter );
    if ($disabled) {
        $filter = "(&(objectClass=posixAccount)(pwdLockout=TRUE))";
    } else {
        $filter = "(&(objectClass=posixAccount)(pwdLockout=FALSE))";
    }

    &return_message( "DEBUG", "Base: ${ou_users},${base}" );
    &return_message( "DEBUG", "Search filter: ${filter}" );
    my $searchresult = $ldap->search(
        base   => "${ou_users},${base}",
        filter => "${filter}",
        scope  => "one"
    );
    if ( $searchresult->code ) {
        &return_message( "FATAL",
            "An error occurred binding to the LDAP server: "
              . ldap_error_text( $searchresult->code ) );
    }
    my $entries = $searchresult->entries;
    &return_message( "DEBUG", "Results Returned: $entries" );
    if ( $entries == 0 ) {
        &return_message( "DEBUG", "No results returned" );
    } else {
        foreach my $entry ( $searchresult->entries ) {
            &return_message( "DEV", "$entry:\n" . Dumper($entry) );
            my $locked;
            if ( $entry->get_value('pwdLockout') eq "TRUE" ) {
                $locked = "deleted";
            }
            my @user = (
                $entry->get_value('uid'),
                $entry->get_value('uidNumber'),
                $entry->get_value('gidNumber')
            );
            push( @users, \@user );

            #            push( @users,
            #                    $entry->get_value('uid') . "\t"
            #                  . $entry->get_value('uidNumber') . "\t"
            #                  . $entry->get_value('gidNumber') );
            $locked = "";
        }
    }

    # Display users in the group
    my $user_count = @users;
    print "\n";
    if ( $user_count > 0 ) {
        printf( "  %-25s %10s %10s\n", "user", "uid", "gid" );
        print "  ===============================================\n\n";
        for ( my $i = 0 ; $i < $user_count ; $i++ ) {
            printf( "  %-25s %10s %10s",
                $users[$i][0], $users[$i][1], $users[$i][2] );
            print "\n";
        }
    } else {
        print "  No users are in LDAP\n";
    }
    print "\n";
    return 0;
}

##############################
# show a group and its users #
##############################
sub show_group {

    # show_group($attribute,$value);
    my ( $attribute, $value ) = @_;
    my ( @users, $gid, $cn );

    # only check LDAP groups if this is not the default group
    if ( ( $value ne $standard_group ) && ( $value ne $standard_gid ) ) {

        # check if the group exists in LDAP
        if ( !&get_id_name( $ou_groups, $attribute, $value ) ) {
            &return_message( "WARN", "Group ${value} does not exist" );
            exit 1;
        }

        # get the list users in this group
        my $filter = "(&(objectClass=posixGroup)(${attribute}=${value}))";
        &return_message( "DEBUG", "Base: ${ou_groups},${base}" );
        &return_message( "DEBUG", "Search filter: ${filter}" );
        my $searchresult = $ldap->search(
            base   => "${ou_groups},${base}",
            filter => "${filter}",
            scope  => "one"
        );
        if ( $searchresult->code ) {
            &return_message( "FATAL",
                "An error occurred binding to the LDAP server: "
                  . ldap_error_text( $searchresult->code ) );
        }
        my $entries = $searchresult->entries;
        &return_message( "DEBUG", "Results Returned: $entries" );
        if ( $entries == 0 ) {
            &return_message( "DEBUG", "No results returned" );
        } else {
            &return_message( "DEBUG", "Processing users in the group" );
            foreach my $entry ( $searchresult->entries ) {
                push( @users, $entry->get_value('memberUid') );
                $gid = $entry->get_value('gidNumber');
                $cn  = $entry->get_value('cn');
            }

        }

    } else {

   # we are only going to scan the $ou_users with $standard_gid and build a list
        my $filter = "(&(objectClass=posixAccount)(gidNumber=${standard_gid}))";
        $gid = $standard_gid;
        $cn  = $standard_group;
        &return_message( "DEBUG", "Base: ${ou_users},${base}" );
        &return_message( "DEBUG", "Search filter: ${filter}" );
        my $searchresult = $ldap->search(
            base   => "${ou_users},${base}",
            filter => "${filter}",
            scope  => "one"
        );
        if ( $searchresult->code ) {
            &return_message( "FATAL",
                "An error occurred binding to the LDAP server: "
                  . ldap_error_text( $searchresult->code ) );
        }
        my $entries = $searchresult->entries;
        &return_message( "DEBUG", "Results Returned: $entries" );
        if ( $entries == 0 ) {
            &return_message( "DEBUG", "No results returned" );
        } else {
            foreach my $entry ( $searchresult->entries ) {
                push( @users, $entry->get_value('uid') );
            }
        }
    }

    # Display users in the group
    my $user_count = @users;
    print "  Users in the group ${cn} ($gid)\n";
    print "  =================================\n\n";
    if ( $user_count > 0 ) {
        for ( my $i = 0 ; $i < $user_count ; $i++ ) {
            print "  $users[$i]\n";
        }
    } else {
        print "  No users are in this group\n";
    }
    print "\n";
    return 0;
}

###################
# show the groups #
###################
sub show_groups {

    my $filter = "(&(objectClass=posixGroup))";
    &return_message( "DEBUG", "Base: ${ou_groups},${base}" );
    &return_message( "DEBUG", "Search filter: ${filter}" );
    my $searchresult = $ldap->search(
        base   => "${ou_groups},${base}",
        filter => "${filter}",
        scope  => "one"
    );
    if ( $searchresult->code ) {
        &return_message( "FATAL",
            "An error occurred binding to the LDAP server: "
              . ldap_error_text( $searchresult->code ) );
    }
    my $entries = $searchresult->entries;
    &return_message( "DEBUG", "Results Returned: $entries" );
    if ( $entries == 0 ) {
        &return_message( "DEBUG", "No results returned" );
    } else {
        &return_message( "DEBUG", "Processing list of groups" );
        printf( "  %8s %25s\n", "group", "gid" );
        print "  ==================================\n";
        foreach my $entry ( $searchresult->entries ) {
            printf( "  %8s %25s\n",
                $entry->get_value('gidNumber'),
                $entry->get_value('cn') );
        }

    }
    return 0;

}

########################
# show SSH public keys #
########################
sub show_ssh_public_keys {
    my $user = shift;

    # check the user exists
    if ( !&get_id_name( $ou_users, "uid", $user ) ) {
        &return_message( "WARN", "User ${user} does not exist" );
        exit 1;
    }

    # now show those keys

    my $filter = "(&(objectClass=posixAccount)(uid=${user}))";

    &return_message( "DEBUG", "Base: ${ou_users},${base}" );
    &return_message( "DEBUG", "Search filter: ${filter}" );
    my $result = $ldap->search(
        base   => "${ou_users},${base}",
        filter => "${filter}",
        attrs  => ['sshPublicKey'],
        scope  => "one"
    );
    if ( $result->code ) {
        &return_message( "FATAL",
            "An error occurred binding to the LDAP server: "
              . ldap_error_text( $result->code ) );
    }
    my $entries = $result->entries;
    &return_message( "DEBUG", "Results Returned: $entries" );
    &return_message( "DEV", "$result->entries\n" . Dumper( $result->entries ) );
    if ( $entries == 0 ) {
        &return_message( "DEBUG", "No results returned" );
        return 1;
    }
    elsif ( $entries == 1 ) {

        # we are good to show stuff
        my @entry = $result->entries;

        my @keys      = $entry[0]->get_value('sshPublickey');

        my $key_count = @keys;
        if ( $key_count == 1 ) {
            if ( $keys[0] eq '' ) { $key_count = 0; }
        }
        &return_message( "DEBUG", "SSH key count: ${key_count}" );
        if ( $key_count == 0 ) {
            &return_message( "ERROR", "${user} does not have ssh keys" );
            return 1;
        }
        print "  ${user} ssh public keys\n";
        print "  =======================\n\n";
        my $k = 1;
        for ( my $i = 0 ; $i < $key_count ; $i++ ) {
            print "  key [" . $k . "]\n";
            print "  -------\n";
            print $keys[$i] . "\n\n";         
            $k++;
        }
    }
    elsif ( $entries > 1 ) {
        &return_message( "FATAL",
"More then one result returned for ${filter}, please fix ${ou_users}"
        );
    }

}

######################
# Check SUDO command #
######################
sub check_sudo_command {
    my ( $sudo_role, $sudo_command ) = @_;

    if ( &check_sudo_role($sudo_role) ) {
        &return_message( "FATAL", "sudo role: ${sudo_role} does not exist" );
    }

    # check the command to LDAP
    my $filter =
      "(&(objectClass=sudoRole)(cn=${sudo_role})(sudoCommand=$sudo_command))";
    &return_message( "DEBUG", "Base: ${ou_sudoers},${base}" );
    &return_message( "DEBUG", "Search filter: ${filter}" );
    my $result = $ldap->search(
        base   => "${ou_sudoers},${base}",
        filter => $filter,
        scope  => "one"
    );
    if ( $result->code ) {
        &return_message( "FATAL",
            "An error occurred binding to the LDAP server: "
              . ldap_error_text( $result->code ) );
    }
    my $entries = $result->entries;

    &return_message( "DEBUG", "Results Returned: $entries" );
    if ( $result->count == 0 ) {
        &return_message( "DEBUG", "No results returned" );
        return 1;
    }
    elsif ( $result->count == 1 ) {
        return 0;
    }

    # if failed return 1
    return 1;
}

###################
# Check SUDO role #
###################
sub check_sudo_role {
    my $sudo_role = shift;

    my $filter = "(&(objectClass=sudoRole)(cn=${sudo_role}))";
    &return_message( "DEBUG", "Base: ${ou_sudoers},${base}" );
    &return_message( "DEBUG", "Search filter: ${filter}" );
    my $result = $ldap->search(
        base   => "${ou_sudoers},${base}",
        filter => $filter,
        scope  => "one"
    );
    if ( $result->code ) {
        &return_message( "FATAL",
            "An error occurred binding to the LDAP server: "
              . ldap_error_text( $result->code ) );
    }
    my $entries = $result->entries;

    &return_message( "DEBUG", "Results Returned: $entries" );
    if ( $result->count == 0 ) {
        &return_message( "DEBUG", "No results returned" );
        return 1;
    }
    elsif ( $result->count == 1 ) {
        return 0;
    }

    # if failed return 0
    return 1;
}

################################
# Check SSH public key matches #
################################
sub check_ssh_public_key {
    my ( $user, $file ) = @_;
    my %hash           = &match_ssh_public_key( $user, $file );
    my $match_count    = @{ $hash{match} };
    my $no_match_count = @{ $hash{no_match} };

    # print the keys which match
    my $j       = 1;
    my $message = "";

    for ( my $i = 0 ; $i < $match_count ; $i++ ) {
        $message .= "  [$j]  " . $hash{match}[$i] . "\n";
        $j++;
    }
    &return_message( "INFO", "${match_count} key(s) match\n\n${message}" );
    $message = "";
    $j       = 1;
    for ( my $i = 0 ; $i < $no_match_count ; $i++ ) {
        $message .= "  [$j]  " . $hash{no_match}[$i] . "\n";
        $j++;
    }

    &return_message( "INFO",
        "${no_match_count} key(s) do not match\n\n${message}" );

    # print the keys which do not match

    if ( $no_match_count > 0 ) {
        return 1;
    }
    return 0;
}

################################
# Match SSH public key matches #
################################
sub match_ssh_public_key {

    # match_ssh_public_key($user,$ssh_file)
    # then return a hash
    my ( $user, $file ) = @_;

    # check the user exists
    if ( !&get_id_name( $ou_users, "uid", $user ) ) {
        &return_message( "WARN", "User ${user} does not exist" );
        exit 1;
    }

    # get a list of keys from authorized_keys
    my @keys_file = &read_ssh_key_file($file);

    # get number of keys from ldap
    my $filter = "(&(objectClass=posixAccount)(uid=${user}))";
    &return_message( "DEBUG", "Base: ${ou_users},${base}" );
    &return_message( "DEBUG", "Search filter: ${filter}" );
    my $result = $ldap->search(
        base   => "${ou_users},${base}",
        filter => "${filter}",
        attrs  => ['sshPublicKey'],
        scope  => "one"
    );
    if ( $result->code ) {
        &return_message( "FATAL",
            "An error occurred binding to the LDAP server: "
              . ldap_error_text( $result->code ) );
    }
    my $entries = $result->entries;
    &return_message( "DEBUG", "Results Returned: $entries" );
    &return_message( "DEV", "$result->entries\n" . Dumper( $result->entries ) );
    if ( $entries == 0 ) {
        &return_message( "DEBUG", "No results returned" );
        return 1;
    }
    elsif ( $entries == 1 ) {
        my @entry           = $result->entries;
        my @keys_ldap       = $entry[0]->get_value('sshPublicKey');
        my $keys_ldap_count = @keys_ldap;
        if ( $keys_ldap_count == 1 ) {
            if ( $keys_ldap[0] eq '' ) { $keys_ldap_count = 0; }
        }
        &return_message( "DEBUG", "LDAP SSH key count: ${keys_ldap_count}" );
        my ( @match, @no_match );
        my $keys_file_count = @keys_file;

        # setup the counts for match/no match
        my $key_no_match_count = 0;
        my $key_match_count    = 0;
        my $key_match_tmp      = 0;

        # now loop through LDAP for a match
        for ( my $j = 0 ; $j < $keys_file_count ; $j++ ) {

            # take first key from file array
            for ( my $i = 0 ; $i < $keys_ldap_count ; $i++ ) {
                if ( $keys_file[$j] eq $keys_ldap[$i] ) {
                    push @match, $keys_file[$j];
                    $key_match_count++;
                    $key_match_tmp++;
                }
            }
            if ( $key_match_tmp == 0 ) {
                push @no_match, $keys_file[$j];
                $key_no_match_count++;
            }

            # reset the key match count
            $key_match_tmp = 0;
        }
        &return_message( "DEBUG", "Key match count: $key_match_count" );
        &return_message( "DEBUG", "Key no match count: $key_no_match_count" );

        my %hash;
        $hash{match}    = \@match;
        $hash{no_match} = \@no_match;
        &return_message( "DEV", "%hash:\n" . Dumper(%hash) );
        return %hash;
    }
}

##################
# get id or name #
##################
sub get_id_name {

    # get_id_name($ou,$attribute,$value);
    # return a user/group id or name
    my ( $ou, $attribute, $value ) = @_;

    my ( $objectclass, $return_attribute, $return_value );

    &return_message( "DEBUG", "&get_id_name($ou,$attribute,$value);" );

    given ($ou) {
        when ($ou_users) {
            &return_message( "DEBUG", "Matched: ${ou_users}" );
            $objectclass = "posixAccount";
            if ( $attribute eq "uid" ) {
                $return_attribute = "uidNumber";
            } elsif ( $attribute eq "uidNumber" ) {
                $return_attribute = "uid";
            } else {
                &return_message( "FATAL", "$attribute is not defined" );
            }
        }
        when ($ou_groups) {
            &return_message( "DEBUG", "Matched: ${ou_groups}" );
            $objectclass = "posixGroup";
            if ( $attribute eq "cn" ) {
                $return_attribute = "gidNumber";
            } elsif ( $attribute eq "gidNumber" ) {
                $return_attribute = "cn";
            } else {
                &return_message( "FATAL", "$attribute is not defined" );
            }
        }
        default {
            &return_message( "FATAL",
                "Invalid $ou for get_id_name() function\n" );
        }
    }
    my $filter = "(&(objectClass=${objectclass})(${attribute}=${value}))";
    &return_message( "DEBUG", "Base: ${ou},${base}" );
    &return_message( "DEBUG", "Search filter: ${filter}" );
    &return_message( "DEBUG", "attribute=${attribute}" );
    &return_message( "DEBUG", "return_attribute=${return_attribute}" );

    my $searchresult = $ldap->search(
        base   => "${ou},${base}",
        filter => "${filter}",
        scope  => "one"
    );
    if ( $searchresult->code ) {
        &return_message( "FATAL",
            "An error occurred binding to the LDAP server: "
              . ldap_error_text( $searchresult->code ) );
    }
    my $entries = $searchresult->entries;

    &return_message( "DEBUG", "Results Returned: $entries" );
    if ( $entries == 0 ) {
        &return_message( "DEBUG", "No results returned" );
        return 0;
    }
    elsif ( $entries == 1 ) {
        my $entry = $searchresult->entry(0);
        $return_value = $entry->get_value($return_attribute);
        return $return_value;
    }

    # if failed return 0
    return 0;
}

########################
# read the config file #
########################
sub read_text_config {

    # Read a text-based config file into a single-level hash, die on disk error
    # Usage: loadtextconfig(\%myhash, $myfilename);

    my $file = shift;
    my $config;
    my ( $i, $j ) = ( 0, 0 );

    open( READ, $file )
      || &return_message( "FATAL", "Could not open ${file} $!" );
    while (<READ>) {
        next if /^#|;/;    # ignore commented lines
        $_ =~ s/\r|\n//g;  # remove ending carriage return and/or newline
        s/^\s+//;          # remove leading whitespace
        s/\s+$//g;         # remove trailing whitespace
        next unless length;    # skip blank lines

        ( $i, $j ) = split( /=/, $_, 2 );    # $j holds rest of line
        $j = "" unless ( defined $j );
        $j =~ s/^\s+//;                      # remove leading whitespace
        $config->{$i} = $j;
    }
    close(READ);
    &return_message( "DEV",
        "loadtextconfig ${file}:\n" . Dumper($config) . "\n" );
    return $config;
}

############################
# read ssh public key file #
############################
sub read_ssh_key_file {
    my $file = shift;
    if ( !&locate_file($file) ) {
        &return_message( "FATAL", "${file} does not exist" );
    }
    my @lines;
    my $i = 0;

    # read the file line by line
    # then pass it back as an array excluding blank lines or comments.
    open( FILE, $file )
      || &return_message( "FATAL", "Could not open ${file} $!" );
    while (<FILE>) {
        next if /^#|;/;    # ignore commented lines
        $_ =~ s/\r|\n//g;  # remove ending carriage return and/or newline
        s/^\s+//;          # remove leading whitespace
        s/\s+$//g;         # remove trailing whitespace
        next unless length;    # skip blank lines
        $lines[$i] = $_;
        $i++;
    }
    close(FILE);

    # need to do a better check later
    if ( $i == 0 ) {
        &return_message( "FATAL", "File does not have any ssh keys" );
    }
    &return_message( "DEV", "File contents\n" . Dumper(@lines) );
    return @lines;
}

######################
# find file location #
######################
sub locate_file {
    my ( $file, @locations ) = @_;
    my $count = @locations;
    if ( !$count ) {
        &return_message( "DEBUG", "Checking ${file} exists" );
        if ( -f $file ) {
            return $file;
        }
        return 0;
    }
    &return_message( "DEBUG", "Locating ${file}" );
    for ( my $i = 0 ; $i < $count ; $i++ ) {
        &return_message( "DEBUG", "Checking " . $locations[$i] . "/${file}" );
        if ( -f $locations[$i] . "/${file}" ) {
            return $locations[$i] . "/${file}";
        }
    }
    return 0;
}

##################################
# load the config file variables #
##################################
sub load_config_variables {

    if ( !$input_config ) {
        $config_file = &locate_file( $config_file, @config_locations );
    } else {
        $config_file = &locate_file($input_config);
    }

    my $file_hash;
    if ( !$config_file ) {
        &return_message( "INFO",
            "No config file to load, using built in defaults" );
        return 1;
    } else {
        $file_hash = &read_text_config($config_file);
        &return_message( "INFO", "Loading configuration from $config_file" );
    }
    &return_message( "DEBUG", "Gonna throw some variables around" );
    &return_message( "DEV",   "\n" . Dumper($file_hash) . "\n" );

    # Message level
    if ( $file_hash->{message_level} ) {
        if ( $file_hash->{message_level} < $message_level ) {
            $message_level = $file_hash->{message_level};
        }
    }
    if ( $file_hash->{auto_commit} ) {
        $auto_commit = $file_hash->{auto_commit};
    }
    &return_message( "DEBUG", "Setting auto_commit: ${auto_commit}" );

    # LDAP bind
    if ( $file_hash->{binddn} ) {
        $binddn = $file_hash->{binddn};
    }
    &return_message( "DEBUG", "Setting binddn: $binddn" );
    if ( $file_hash->{bindpw} ) {
        $bindpw = $file_hash->{bindpw};
    }
    &return_message( "DEBUG", "Setting bindpw: <hidden>" );
    if ( $file_hash->{base} ) {
        $base = $file_hash->{base};
    }
    &return_message( "DEBUG", "Setting base: $base" );
    if ( $file_hash->{hostname} ) {
        $hostname = $file_hash->{hostname};
    }
    &return_message( "DEBUG", "Setting hostname: $hostname" );
    if ( $file_hash->{port} ) {
        $port = $file_hash->{port};
    }
    &return_message( "DEBUG", "Setting port: $port" );

    # Organizational Units
    if ( $file_hash->{ou_users} ) {
        $ou_users = $file_hash->{ou_users};
    }
    &return_message( "DEBUG", "Setting ou_users: $ou_users" );
    if ( $file_hash->{ou_groups} ) {
        $ou_groups = $file_hash->{ou_groups};
    }
    &return_message( "DEBUG", "Setting ou_groups: $ou_groups" );
    if ( $file_hash->{ou_sudoers} ) {
        $ou_sudoers = $file_hash->{ou_sudoers};
    }
    &return_message( "DEBUG", "Setting ou_sudoers: $ou_sudoers" );

    # Posix user and group info
    if ( $file_hash->{standard_gid} ) {
        $standard_gid = $file_hash->{standard_gid};
    }
    &return_message( "DEBUG", "Setting standard_gid: $standard_gid" );
    if ( $file_hash->{standard_group} ) {
        $standard_group = $file_hash->{standard_group};
    }
    &return_message( "DEBUG", "Setting standard_group: $standard_group" );
    if ( $file_hash->{show_password} ) {
        $show_password = $file_hash->{show_password};
    }
    &return_message( "DEBUG", "Setting standard_gid: $standard_gid" );
    if ( $file_hash->{default_shell} ) {
        $default_shell = $file_hash->{default_shell};
    }
    &return_message( "DEBUG", "Setting default_shell: $default_shell" );
    if ( $file_hash->{minimum_uid_soft} ) {
        $minimum_uid_soft = $file_hash->{minimum_uid_soft};
    }
    &return_message( "DEBUG", "Setting minimum_uid_soft: $minimum_uid_soft" );
    if ( $file_hash->{minimum_gid_soft} ) {
        $minimum_gid_soft = $file_hash->{minimum_gid_soft};
    }
    &return_message( "DEBUG", "Setting minimum_gid_soft: $minimum_gid_soft" );

    if ( $file_hash->{minimum_uid_hard} ) {
        $minimum_uid_hard = $file_hash->{minimum_uid_hard};
    }
    &return_message( "DEBUG", "Setting minimum_uid_hard: $minimum_uid_hard" );
    if ( $file_hash->{minimum_gid_hard} ) {
        $minimum_gid_hard = $file_hash->{minimum_gid_hard};
    }
    &return_message( "DEBUG", "Setting minimum_gid_hard: $minimum_gid_hard" );

    return 0;
}

# my @add    = ( "user", "group", "sshkey", "sudorole", "sudocmd", "groupuser" );
# my @check  = ( "user", "group", "sshkey", "sudorole", "sudocmd", "uid", "name" );
# my @delete = ( "user", "group", "sshkey", "sudorole", "sudocmd", "groupuser", "purgeuser", "purgeusers", "rmuser" );
# my @modify = ( "user", "group", "sudorole" );
# my @list   = ( "user", "group", "users", "groups", "sshkeys", "disabledusers", "userstatus" );

sub check_actions {
    if (de($action_add)
      + de($action_check)
      + de($action_delete)
      + de($action_modify)
      + de($action_list) > 1) {
    die "only one command may be specified\n"; #OK
    }
    # my $mode;
    # $mode = 'add'    if ($action_add);      # "user", "group", "sshkey", "sudorole", "sudocmd", "groupuser" 
    # $mode = 'check'  if ($action_check);    # "user", "group", "sshkey", "sudorole", "sudocmd", "uid", "name"
    # $mode = 'delete' if ($action_delete);   # "user", "group", "sshkey", "sudorole", "sudocmd", "groupuser", "purgeuser", "purgeusers", "rmuser"
    # $mode = 'modify' if ($action_modify);   # "user", "group", "sudorole"
    # $mode = 'list'   if ($action_list);     # "user", "group", "users", "groups", "sshkeys", "disabledusers", "userstatus"

    if ( de($action_add) ) {
        # ( "user", "group", "sshkey", "sudorole", "sudocmd", "groupuser" );
        given ($action_add) {
            when("user") {
                if ( $input_user && $input_description ) {
                    # lets save a lot of shift'ing in the add_user routine and use a hash.
                    my $details;
                    $details->{"user"}        = $input_user;
                    $details->{"uid"}         = $input_uid;
                    $details->{"gid"}         = $input_default_gid;
                    $details->{"description"} = $input_description;
                    $details->{"home"}        = $input_homedir;
                    $details->{"shell"}       = $input_shell;
                    $details->{"pass"}        = $input_passwd;
                    my $result = &add_user($details);
                    if ( $result == 0 ) {
                        my $uid = &get_id_name( $ou_users, "uid", $input_user );
                        # return 0 - created
                        &return_message( "SUCCESS", "User created ${input_user}:${uid}" );
                    } elsif ( $result == 1 ) {
                        # return 1 - failed
                        &return_message( "ERROR", "Can not create ${input_user}" );
                    } elsif ( $result == 2 ) {
                        my $uid = &get_id_name( $ou_users, "uid", $input_user );
                        # return 2 - already exists :)
                        &return_message( "SUCCESS", "User exists ${input_user}:${uid}" );
                    }
                } else {
                    &return_message( "FATAL", "you need to use the switch --user=<user> --description=\"<description>\"" );
                } 
            } 
            when ("group") {
                if ($input_group) {
                    my $result = &add_group( $input_group, $input_gid );
                    if ( $result == 0 ) {
                        my $gid = &get_id_name( $ou_groups, "cn", $input_group );
                        # return 0 - created
                        &return_message( "SUCCESS", "Group created ${input_group}:${gid}" );
                    } elsif ( $result == 1 ) {
                        # return 1 - failed
                        &return_message( "ERROR", "Can not create ${input_group}" );
                    } elsif ( $result == 2 ) {
                        my $gid = &get_id_name( $ou_groups, "cn", $input_group );

                        # return 2 - already exists :)
                        &return_message( "SUCCESS", "Group exists ${input_group}:${gid}" );
                    }
                }
                else {
                    &return_message( "FATAL", "you need to use the switch --group=<group> or switches --group=<group> --gid=<gid>" );
                }
            }
            when ("sshkey") {
                if ( $input_user && $input_ssh_key_file ) {
                    if ( !&add_ssh_public_key( $input_user, $input_ssh_key_file ) )
                    {
                        &return_message( "SUCCESS", "SSH Key task completed" );
                        exit 0;
                    } else {
                        &return_message( "ERROR", "Could not add SSH Keys to LDAP" );
                        exit 1;
                    }
                } else {
                    &return_message( "FATAL", "you need to use the switch --user=<user> switches --sshfile=<sshfile>" );
                }
            }
            when ("sudorole") {
                if ($input_sudo_role) {
                    my $result = &add_sudo_role($input_sudo_role);
                    if ( !$result ) {
                        &return_message( "SUCCESS", "Created sudo role ${input_sudo_role}" );
                        exit 0;
                    } elsif ( $result == 2 ) {
                        &return_message( "ERROR", "sudo role already exists" );
                        exit 1;
                    } else {
                        &return_message( "ERROR", "Can not create sudo role ${input_sudo_role}" );
                        exit 1;
                    }
                } else {
                    &return_message( "FATAL", "you need to use the switch --sudorole=<role name> for a group use the prefix %" );
                }
            }
            when ("sudocmd") {
                if ( $input_sudo_role && $input_sudo_command ) {
                    my $result = &add_sudo_command( $input_sudo_role, $input_sudo_command );
                    if ( !$result ) {
                        print "added the command ${input_sudo_command}\n";
                    } elsif ( $result == 2 ) {
                        print "${input_sudo_command} already exists for ${input_sudo_role}\n";
                    } else {
                        print "failed to add the command ${input_sudo_command}\n";
                    }
                } else {
                    &return_message( "FATAL", "you need to use the switches --sudorole=<role name> --sudocmd=<command>");
                }    
            }
            when ("groupuser") {
                if ( $input_user && $input_group ) {
                    my $result = &add_group_user( $input_user, $input_group );
                    if ( !$result ) {
                        &return_message( "SUCCESS", "${input_user} added to ${input_group}" );
                        exit 0;
                    } else {
                        &return_message( "ERROR", "Could not add ${input_user} to ${input_group}" );
                        exit 1;
                    }
                } else {
                    &return_message( "FATAL", "you need to use the switch --user=<user> and --group=<group>" );
                    exit 1;
                }    
            }
            default {
                &return_message( "FATAL", "The shit hit the fan: '${action_add}' is not a vaild action" );
                exit 1;
            }
        }
    } elsif ( de($action_check) ) {
        # ( "user", "group", "sshkey", "sudorole", "sudocmd", "uid", "name" );       
        given ($action_check) {            
            when ("user") {
                if ( $input_uid && !$input_user ) {
                    &return_message( "DEBUG", "Only uid has been defined" );
                    &return_message( "DEBUG", "uid: ${input_uid}" );
                    if ( my $user = &get_id_name( $ou_users, "uidNumber", $input_uid ) ) {
                        print "${user}\n";
                        exit 0;
                    } else {
                        print "uid avaliable\n";
                        exit 1;
                    }
                } elsif ( !$input_uid && $input_user ) {
                    &return_message( "DEBUG", "Only user has been defined" );
                    &return_message( "DEBUG", "user: ${input_user}" );
                    if ( my $uid = &get_id_name( $ou_users, "uid", $input_user ) ) {
                        print "${uid}\n";
                        exit 0;
                    } else {
                        print "user avaliable\n";
                        exit 1;
                    }
                } elsif ( $input_uid && $input_user ) {
                    &return_message( "DEBUG", "Both uid and user have been defined" );
                    &return_message( "DEBUG", "uid: ${input_uid}" );
                    &return_message( "DEBUG", "user: ${input_user}" );

                    if ( $input_uid == &get_id_name( $ou_users, "uid", $input_user ) )
                    {
                        print "match\n";
                        exit 0;
                    } else {
                        print "no match\n";
                        exit 1;
                    }
                } else {
                    &return_message( "FATAL", "you need to use the switch --uid=<uid> and/or --user=<user name>" );
                }
            }
            when ("group") {
                if ( $input_gid && !$input_group ) {
                    &return_message( "DEBUG", "Only gid has been defined" );
                    &return_message( "DEBUG", "gid: ${input_gid}" );
                    if ( my $group = &get_id_name( $ou_groups, "gidNumber", $input_gid ) ) {
                        print "${group}\n";
                        exit 0;
                    } else {
                        print "gid avaliable\n";
                        exit 1;
                    }
                } elsif ( !$input_gid && $input_group ) {
                    &return_message( "DEBUG", "Only group has been defined" );
                    &return_message( "DEBUG", "group: ${input_group}" );
                    if ( my $gid = &get_id_name( $ou_groups, "cn", $input_group ) ) {
                        print "${gid}\n";
                        exit 0;
                    } else {
                        print "group avaliable\n";
                        exit 1;
                    }
                } elsif ( $input_gid && $input_group ) {
                    &return_message( "DEBUG",
                        "Both gid and group have been defined" );
                    &return_message( "DEBUG", "gid: ${input_gid}" );
                    &return_message( "DEBUG", "group: ${input_group}" );

                    if ( $input_gid == &get_id_name( $ou_groups, "cn", $input_group ) ) {
                        print "match\n";
                        exit 0;
                    } else {
                        print "no match\n";
                        exit 1;
                    }
                } else {
                    &return_message( "FATAL", "you need to use the switch --uid=<uid> and/or --user=<user name>" );
                }
            }
            when ("sshkey") {
                if ( $input_user && $input_ssh_key_file ) {
                    if ( !&check_ssh_public_key( $input_user, $input_ssh_key_file ) ) {
                        &return_message( "SUCCESS", "SSH Keys match" );
                        exit 0;
                    } else {
                        &return_message( "ERROR", "SSH Keys do not match" );
                        exit 1;
                    }
                } else {
                    &return_message( "FATAL", "you need to use the switch --user=<user> or --sshfile=<authorized_keys>" );
                }
            }
            when ("sudorole") {
                if ($input_sudo_role) {
                    if ( !&check_sudo_role($input_sudo_role) ) {
                        print "taken\n";
                        exit 0;
                    } else {
                        print "avaliable\n";
                        exit 1;
                    }
                } else {
                    &return_message( "FATAL", "you need to use the switch --sudorole=<role name> for a group use the prefix %" );
                }   
            }
            when ("uid") {
                if ( $input_uid && !$input_gid ) {
                    my $user = &get_id_name( $ou_users, "uidNumber", $input_uid );
                    if ( !$user ) {
                        &return_message( "DEBUG", "uid=${input_uid} does not exist" );
                        print "avaliable\n";
                        exit 1;
                    } else {
                        &return_message( "DEBUG", "uid=${input_uid} user=${user}" );
                        print "taken\n";
                        exit 0;
                    }
                } elsif ( !$input_uid && $input_gid ) {
                    my $group = &get_id_name( $ou_groups, "gidNumber", $input_gid );
                    if ( !$group ) {
                        &return_message( "DEBUG", "gid=${input_gid} does not exist" );
                        print "avaliable\n";
                        exit 1;
                    } else {
                        &return_message( "DEBUG", "gid=${input_gid} group=${group}" );
                        print "taken\n";
                        exit 0;
                    }
                } elsif ( $input_uid && $input_gid ) {
                    &return_message( "FATAL", "you must only use one switch --uid=<uid> or --gid=<gid>" );
                } else {
                    &return_message( "FATAL", "you need to use the switch --uid=<uid> or --gid=<gid>" );
                }
            }
            when ("name") {
                if ( $input_user && !$input_group ) {
                    my $uid = &get_id_name( $ou_users, "uid", $input_user );
                    if ( !$uid ) {
                        &return_message( "DEBUG",
                            "user=${input_user} does not exist" );
                        print "avaliable\n";
                        exit 1;
                    } else {
                        &return_message( "DEBUG", "user=${input_user} uid=${uid}" );
                        print "taken\n";
                        exit 0;
                    }
                } elsif ( !$input_user && $input_group ) {
                    my $gid = &get_id_name( $ou_groups, "cn", $input_group );
                    if ( !$gid ) {
                        &return_message( "DEBUG",
                            "group=${input_group} does not exist" );
                        print "avaliable\n";
                        exit 1;
                    } else {
                        &return_message( "DEBUG",
                            "group=${input_group} gid=${gid}" );
                        print "taken\n";
                        exit 0;
                    }
                } elsif ( $input_user && $input_group ) {
                    &return_message( "FATAL", "you must only use one switch --user=<user> or --group=<group>" );
                } else { 
                    &return_message( "FATAL", "you need to use the switch --user=<user> or --group=<group>" );
                }
            }
            default {
                &return_message( "FATAL", "The shit hit the fan: '${action_check}' is not a vaild action" );
                exit 1;
            }
        }    
    } elsif ( de($action_delete) ) {
        # ( "user", "group", "sshkey", "sudorole", "sudocmd", "groupuser", "purgeuser", "purgeusers", "rmuser" );
        given ($action_delete) {
            when ("user") {
                if ($input_user) {
                    if ( !&change_user_status( $input_user, "lock" ) ) {
                        print "${input_user} deleted\n";
                    }
                } else {
                    &return_message( "FATAL", "you need to use the switch --user=<user>" );
                    exit 1;
                }
            }
            when ("group") {
                if ($input_group) {
                    my $result = &delete_group($input_group);
                    if ( $result == 0 ) {
                        &return_message( "SUCCESS", "Deleted ${input_group}" );
                    } elsif ( $result == 2 ) {
                        &return_message( "WARN", "To deleted ${input_group} please add the switch --commit" );
                    } elsif ( $result == 3 ) {
                        &return_message( "ERROR", "Failed to delete ${input_group} : group does not exist" );
                    } else {
                        &return_message( "ERROR", "Failed to delete ${input_group}" );
                    }
                } else {
                    &return_message( "FATAL", "you need to use the switch --group=<group>" );
                }
            }
            when ("sshkey") {
                if ( ($input_user) && (   ( !$input_ssh_key && $input_ssh_key_file ) or ( $input_ssh_key && !$input_ssh_key_file ) ) ) {
                    my ( $attribute, $value );
                    if ($input_ssh_key) {
                        $attribute = 'key';
                        $value     = $input_ssh_key;
                    }

                    if ($input_ssh_key_file) {
                        $attribute = 'file';
                        $value     = $input_ssh_key_file;
                    }
                    my $result = &delete_ssh_public_key( $input_user, $attribute, $value );
                    if ($result) {
                        &return_message( "ERROR", "Failed to delete ${input_user} ssh key" );
                        return 1;
                    } else {
                        &return_message( "SUCCESS", "Deleted ${input_user} ssh key" );
                        return 0;
                    }
                } else {
                    &return_message( "FATAL", "you need to use the switch --user=<user> --sshkey=<number> or --sshfile=<file>" );
                }    
            }
            when ("sudorole") {
                if ($input_sudo_role) {
                    my $result = &delete_sudo_role($input_sudo_role);
                    if ( !$result ) {
                        print "${input_sudo_role} deleted\n";
                        exit 0;
                    } elsif ( $result == 1 ) {
                        &return_message( "WARN", "To deleted ${input_sudo_role} please add the switch --commit" );
                        exit 1;
                    }
                } else {
                    &return_message( "FATAL", "you need to use the switch --sudorole=<role name> for a group use the prefix %" );
                }    
            }
            when ("sudocmd") {
                if ( $input_sudo_role && $input_sudo_command ) {
                    my $result = &delete_sudo_command( $input_sudo_role, $input_sudo_command );
                    if ( !$result ) {
                        print "deleted the command ${input_sudo_command}\n";
                    } elsif ( $result == 2 ) {
                        print "${input_sudo_command} does not exists for ${input_sudo_role}\n";
                    } else {
                        print "failed to delete the command ${input_sudo_command}\n";
                    }
                } else {
                    &return_message( "FATAL", "you need to use the switches --sudorole=<role name> --sudocmd=<command>" );
                }    
            }
            when ("groupuser") {
                if ( $input_user && $input_group ) {
                    my $result = &delete_group_user( $input_user, $input_group );
                    if ( !$result ) {
                        &return_message( "SUCCESS", "${input_user} deleted from ${input_group}" );
                        exit 0;
                    } elsif ( $result == 2 ) {
                        &return_message( "SUCCESS", "${input_user} not in ${input_group}" );
                        exit 0;
                    } else {
                        &return_message( "ERROR",
                            "Could not delete ${input_user} from ${input_group}" );
                        exit 1;
                    }
                } else {
                    &return_message( "FATAL", "you need to use the switch --user=<user> and --group=<group>" );
                    exit 1;
                }    
            }
            when ("purgeuser") {
                if ($input_user) {
                    my $result = &delete_user( $input_user, "purge" );
                    if ( $result == 0 ) {
                        &return_message( "SUCCESS", "Deleted ${input_user}" );
                        exit 0;
                    } elsif ( $result == 2 ) {
                        &return_message( "WARN", "To deleted ${input_user} please add the switch --commit" );
                    } elsif ( $result == 3 ) {
                        &return_message( "ERROR", "${input_user} is not disabled, can not purge the account" );
                    } else {
                        &return_message( "ERROR", "Failed to delete ${input_user}" );
                        exit 1;
                    }
                } else {
                    &return_message( "FATAL", "you need to use the switch --user=<user>" );
                    exit 1;
                }   
            }
            when ("purgeusers") {
                my $result = &purge_users;
                if ( !$result ) {
                    print "users purged\n";
                } elsif ( $result == 1 ) {
                    print "no users to purge\n";
                } elsif ( $result == 2 ) {
                    &return_message( "WARN", "To purge users please add the switch --commit" );
                }    
            }
            when ("rmuser") {
                if ($input_user) {
                    my $result = &delete_user( $input_user, "delete" );
                    if ( $result == 0 ) {
                        &return_message( "SUCCESS", "Deleted ${input_user}" );
                        exit 0;
                    } elsif ( $result == 2 ) {
                        &return_message( "WARN", "To deleted ${input_user} please add the switch --commit" );
                    } else {
                        &return_message( "ERROR", "Failed to delete ${input_user}" );
                        exit 1;
                    }
                } else {
                    &return_message( "FATAL", "you need to use the switch --user=<user>" );
                    exit 1;
                }
            }
            default {
                &return_message( "FATAL", "The shit hit the fan: '${action_delete}' is not a vaild action" );
                exit 1;
            }
        }
    } elsif ( de($action_modify) ) {
        # ( "user", "group", "sudorole" );
        given ($action_modify) {
            when ("user") {
                my $details;
                $details->{"user"}        = $input_user;
                $details->{"uid"}         = $input_uid;
                $details->{"gid"}         = $input_default_gid;
                $details->{"description"} = $input_description;
                $details->{"home"}        = $input_homedir;
                $details->{"shell"}       = $input_shell;
                $details->{"pass"}        = $input_passwd;                    
                
                if ($details->{"user"}) {                    
                    my $result = &modify_user( $input_rename_to, $details );

                    if ( !$result ) {
                        &return_message( "SUCCESS", "Modified $details->{'user'}" );
                        exit(0);
                    } else {
                        &return_message( "ERROR", "Could not modify $details->{'user'}" );
                        exit 1;
                    }
                } else {
                    &return_message( "FATAL", "you need to use the switch --user=<user> with --renameto=<user> and/or --uid=<uid> and other user switches!!!" );
                }
            }
            when ("group") {
                if ($input_group) {
                    my $result = &modify_group( $input_rename_to, $input_group, $input_gid );
                    if ( !$result ) {
                        &return_message( "SUCCESS", "Modified ${input_group}" );
                        exit(0);
                    } else {
                        &return_message( "ERROR", "Could not modify ${input_group}" );
                        exit 1;
                    }
                } else {
                    &return_message( "FATAL", "you need to use the switch --group=<group> with --renameto=<group> and/or --gid=<gid>" );
                }    
            }
            when ("sudorole") {
                print "modify=sudorole: is in progress! - feedback will be highly appreciated."
            }
            default {
                &return_message( "FATAL", "The shit hit the fan: '${action_delete}' is not a vaild action" );
                exit 1;
            }
        }
    } elsif ( de($action_list) ) {
        # ( "user", "group", "users", "groups", "sshkeys", "disabledusers", "userstatus" );
        given ($action_list) {
            when ("user") {
                if ( ( !$input_user && $input_uid ) || ( $input_user && !$input_uid ) )
                {
                    if ($input_user) {
                        &return_message( "DEBUG", "user: ${input_user}" );
                        &show_user( "uid", $input_user );
                    } elsif ($input_uid) {
                        &return_message( "DEBUG", "uid: ${input_uid}" );
                        &show_user( "uidNumber", $input_uid );
                    }
                } elsif ( $input_user && $input_uid ) {
                    &return_message( "FATAL", "you must only use one switch --user=<user> or --uid=<uid>" );
                } else {
                    &return_message( "FATAL", "you need to use the switch --user=<user> or --uid=<uid>" );
                }    
            }
            when ("group") {
                if ( ( !$input_group && $input_gid ) || ( $input_group && !$input_gid ) ) {
                    if ($input_group) {
                        &return_message( "DEBUG", "group: ${input_group}" );
                        &show_group( "cn", $input_group );

                    } elsif ($input_gid) {
                        &return_message( "DEBUG", "gid: ${input_gid}" );
                        &show_group( "gidNumber", $input_gid );
                    }
                } elsif ( $input_group && $input_gid ) {
                    &return_message( "FATAL", "you must only use one switch --group=<group> or --gid=<gid>" );
                } else {
                    &return_message( "FATAL", "you need to use the switch --group=<group> or --gid=<gid>" );
                }    
            }
            when ("users") {
                &show_users;                
            }
            when ("groups") {
                &show_groups;
            }
            when ("sshkeys") {
                if ($input_user) {
                    &show_ssh_public_keys($input_user);
                } else {
                    &return_message( "FATAL", "you need to use the switch --user=<user>" );
                }    
            }
            when ("disabledusers") {
                &show_users("disabled");
            }
            when ("userstatus") {
                if ($input_user) {
                    if ( &get_user_status($input_user) eq "TRUE" ) {
                        print "disabled\n";
                        exit 1;
                    } else {
                        print "enabled\n";
                        exit 0;
                    }
                } else {
                    &return_message( "FATAL", "you need to use the switch --user=<USER>" );
                }    
            }
            default {
                &return_message( "FATAL", "The shit hit the fan: '${action_list}' is not a vaild action" );
                exit 1;
            }

        }        
    }
}

################
# Main Program #
################

# we shall take the command line message level
if ( $log_level && ( ( $log_level > 0 ) && ( $log_level < 7 ) ) ) {
    $message_level = $log_level;
}

if ($devdebug) {
    $message_level = 1;
    &return_message( "DEBUG",
        "Enabled developer debugging, warning lots of output, and hotter cpu" );
}

# if the switch --debug is set we will reset the message level
if ( $debug && !$devdebug ) {
    $message_level = 2;
    &return_message( "DEBUG", "Enabled debugging" );
}

# load the config from disk
&load_config_variables;

if ($show_version) {
    print "${program}-${version}\n";
    exit(0);
}

if ($man) {
    pod2usage( -verbose => 2, -input => $0 ) if $man;
    exit 0;
}

if ($help) {
    &usage;
}

# connect to LDAP server.
$ldap = Net::LDAP->new($uri)
  or
  &return_message( "FATAL", "Unable to connect to LDAP server $hostname: $@" );

# now bind with supplied binddn and password
my $result = $ldap->bind( dn => $binddn, password => $bindpw );
if ( $result->code ) {
    &return_message( "FATAL",
        "An error occurred binding to the LDAP server: "
          . ldap_error_text( $result->code ) );
}

if (de($action_add)
  + de($action_check)
  + de($action_delete)
  + de($action_modify)
  + de($action_list) == 0) {
  &return_message( "DEBUG", "No Action has been defined" );
  &usage;
}

if ( grep /^[Yy][Ee][Ss]$/, $auto_commit ) {
    $commit = 1;
    &return_message( "DEBUG", "Auto commit is enabled" );
} else {
    &return_message( "DEBUG", "Auto commit is disabled" );
}

&check_actions;

1;
__END__

=head1 NAME

ldapadmin - create, delete or modify unix users, groups and sudoers permissions in LDAP

=head1 SYNOPSIS

=over 8

=item B<ldapadmin> 

First option must be a mode specifier.

Actions:

    -a, --add               add    ["user", "group", "sshkey", "sudorole", "sudocmd", "groupuser"]
    -c, --check             check  ["user", "group", "sshkey", "sudorole", "sudocmd", "uid", "name"]
    -d, --delete            delete ["user", "group", "sshkey", "sudorole", "sudocmd", "groupuser", "purgeuser", "purgeusers", "rmuser"]
    -m, --modify            modify ["user", "group", "sudorole"]
    -l, --list              list   ["user", "group", "users", "groups", "sshkeys", "disabledusers", "userstatus"]
    -h, --help              display this help and exit
        --man               display man page
        --debug             increase verbosity level by one
        --loglevel=<LEVEL>  level is between 1-6, 1 being debug
        --version           output version information and exit


Common Options: 

  [--comment="<comment>"] [--config=<config_file>] [--commit] [--defaultguid=<gid>] 
  [--homedir=<home_dir] [--user=<user>] [--uid=<uid>] [--group=<group>]
  [--gid=<gid>] [--renameto=<user/group>] [--shell=<shell>] [--sshkey=<key_number>]
  [--sshfile=<authorized_keys>] [--sudorole=<role>] [--sudocmd=<command>]

=back

=head1 DESCRIPTION

Default settings can be modifed in the configuration file.


=head1 OPTIONS

=over 8

=item B<First option must be a mode specifier.>

=item I<-a, --add>

add    ["user", "group", "sshkey", "sudorole", "sudocmd", "groupuser"]

=item I<-c, --check>

check  ["user", "group", "sshkey", "sudorole", "sudocmd", "uid", "name"]

=item I<-d, --delete>

delete ["user", "group", "sshkey", "sudorole", "sudocmd", "groupuser", "purgeuser", "purgeusers", "rmuser"]

=item I<-m, --modify>

modify ["user", "group", "sudorole"]

=item I<-l, --list>

list   ["user", "group", "users", "groups", "sshkeys", "disabledusers", "userstatus"]

=item B<--comment>=I<COMMENT>

Any text string. It is generally a short description of the login, and is currently used as the field for the user's full name.

=item B<--config>=I<FILE>

The file sets the connection settings to LDAP and default user and group details. If this file is ommited B<ldapadmin> will search the following locations /usr/local/accesscontrol/etc, /usr/local/etc, /etc for I<ldapadmin.cfg>

=item B<--commit>

This is used in the functions B<deluser> and B<delgroup> to confirm that you wish to delete the user or group.

=item B<--defaultgid>=I<GID>

This is the default group which the user belongs to, the default is to set the gid to B<100> which is the B<users> group.

=item B<--homedir>=I<HOME_DIR>

The new user will be created using I<HOME_DIR> as the value for the user's login directory. The default is to append the I<USER> name to I</home> and use that as the login directory name. The directory I<HOME_DIR> does not have to exist but will be created if it is missing.

=item B<--user>=I<USER>

The login name for the user.

=item B<--uid>=I<UID>

The users uid

=item B<--shell>=I<SHELL>

The deault shell for the user. Vaild shells: bash, csh, ksh, sh, nologin

=item B<--password>=I<PASSWORD>

The password for the user, insert the password as I<md5crypt>

=item B<--group>=I<GROUP>

The name of a group.

=item B<--gid>=I<GID>

The groups ID number.

=item B<--renameto>=I<USER/GROUP>

Rename field, used when you need to rename a user or group

=item B<--sshkey>=I<SSHKEY>

The public SSH key to delete, you can get the number by doing B<showsshkeys>.

=item B<--sshfile>=I<AUTHORIZED_KEYS>

A file which contains a users public SSH keys, this is the same format as authorized_keys file.

=item B<--sudocmd>=I<command>

The command which the sudo role can do

=item B<--sudorole>=I<role>

The sudo role can either be a user or group:

for a user sudo role; just enter there username

for a group sudo role; enter % before the group e.g. %sysops

=item B<--help>

Print a brief help message and exits.

=item B<--man>

Prints the manual page and exits.

=back

=head1 EXAMPLES

=over 8
=begin text 

B<Add Actions>
 Add user:
    ldapadmin -a user --user=<s> --comment=<s> [ --uid=<i> --homedir=<s> --shell=<s> --defaultgid=<i> --password=<s> ]
 Add user to a group:
    ldapadmin -a groupuser --user=<s> --group=<s>
 Add group:
    ldapadmin -a group --group=<s> [ --gid=<i> ]
 Add SSH key:
    ldapadmin -a sshkey --user=<s> --sshfile=<s>
 Add SUDO role:
    ldapadmin -a sudorole --sudorole=<s>
 Add SUDO command to role:
    ldapadmin -a sudocmd --sudorole=<s> --sudocmd=<s>

B<Check Actions>
 Check user:
    ldapadmin -c user --user=<s> [ --uid=<i> ]
 Check group:
    ldapadmin -c group --user=<s> [ --gid=<i> ]
 Check SSH key:
    ldapadmin -c sshkey --user=<s> --sshfile=<s>
 Check SUDO role:
    ldapadmin -c sudorole --sudorole=<s>
 Check SUDO command exist:
    ldapadmin -c sudocmd --sudorole=<s> --sudocmd=<s>
  
B<Delete Actions>
 Delete user:
    ldapadmin -d user --user=<s> [ --commit ]
 Delete user from group:
    ldapadmin -d user --user=<s> --group=<s>
 Delete a group:
    ldapadmin -d group --group=<s> [ --commit ]
 Delete SSH key:
    ldapadmin -d sshkey --user=<s> --sshkey=<i> or --sshfile=<s>
 Delete SUDO role:
    ldapadmin -d sudorole --sudorole=<s> [ --commit ]
 Delete SUDO command:
    ldapadmin -d sudocmd --sudorole=<s> --sudocmd=<s>    

B<Modify Actions>
 Modify user:
    ldapadmin -m user --user=<i> [ --renameto=<s> --uid=<s> --description=<s> --homedir=<i> --shell=<s> ]
 Modify group:
    ldapadmin -m group --group=<i> [--renameto=<s> --gid=<s> ]

B<List Actions>
 List user:
    ldapadmin -l user --user=<s> --user=<i> [ --uid=<s> ]
 List all users:
    ldapadmin -l users
 List group:
    ldapadmin -l group [ --gid=<i> ]
 List groups:
    ldapadmin -l groups
 List SSH keys:
    ldapadmin -l sshkeys --user=<s>

=end text

=back

=head1 REQUIRES

Perl => v5.10

L<Net::LDAP>
L<Getopt::Long>
L<Data::Dumper>
L<Pod::Usage>


=head1 AUTHOR

Danny Cooper - L<dannyjc@gmail.com>

Michalis K - L<mihaliz@gmail.com>


=head1 SEE ALSO

L<perlpod>, L<perlpodspec>

=cut

To Do:
## Posix
## SUDOers