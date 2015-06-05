#!/usr/bin/perl -T
#
#  Author: Hari Sekhon
#  Date: 2014-11-23 17:12:26 +0000 (Sun, 23 Nov 2014)
#
#  https://github.com/harisekhon/toolbox
#
#  License: see accompanying Hari Sekhon LICENSE file
#
#  vim:ts=4:sts=4:sw=4:et

$DESCRIPTION = "Sets up FreeIPA Kerberos for Hortonworks Ambari, including creating Kerberos principals, exporting keytabs and distributing to nodes.

MAKE SURE YOU 'export KRB5CCNAME=/tmp/krb5cc_\$UID; kinit admin' BEFORE RUNNING THIS PROGRAM - you will need to have a valid admin Kerberos ticket to create IPA users.


Uses the Principals CSV generated by Ambari as part of the Enable Security wizard. You can write your own CSV for other Hadoop distributions or other purposes as long as you use the same format:

Host,Description,Principal,Keytab Name,Export Dir,User,Group,Octal permissions


Requirements:

1. Creating Kerberos principals:
    - uses 'ipa' command line tool (ipa-admintools package)
    - Kerberos ticket:
        - export KRB5CCNAME=/tmp/krb5cc_\$UID
        - krb5.conf 'forwardable = yes' (should be set up as part of IPA client install, this allows FreeIPA's XML RPC server to use your credential to create users)
        - kinit admin

2. Exporting keytabs:
    - re-exporting keytabs invalidates all currently existing keytabs for those given principals - will prompt for confirmation before proceeding to export service and user keytabs (if this is your first cluster initial setup use --export-service-keytabs=yes --export-user-keytabs=yes to skip prompts)
    - if exporting keytabs and not using --server FQDN matching LDAP SSL certificate, export will fail unless supplying LDAP bind credentials (eg. -d uid=admin,cn=users,cn=accounts,dc=domain,dc=com -w mypassword)
    - adding hosts to an existing cluster or building subsequent clusters in same IPA realm you should specify \"--export-user-keytabs=no\" and run from the original host to pick up the previously exported user keytabs for distribution. Re-exporting user principal keytabs will invalidate the smoketest users that Ambari uses as part of service startup on the existing services
    - if adding services and the CSV only contains the new service principals then you should export the service and user keytabs for that service

3. Deploying keytabs to hosts requires:
    - openssh-clients and rsync to be installed on all hosts
    - an SSH key to root on those hosts
    - can supply a specific SSH private via --ssh-key

4. The host that this program is run on should be able to resolve all the Hadoop user and group account IDs from FreeIPA in order to set the right permmissions, otherwise they'll be set to root:root.

5. If deploying subsequent Hortonworks clusters within a single IPA realm either, avoid re-exporting smoketest user keytabs (ambari-qa, hdfs, hbase) otherwise it'll break the Ambari service startup checks on already existing clusters:
    a. specify different smoketest user principals per cluster in the Enable Security Wizard
    b. run this program from same host with --no-user-export for the 2nd cluster onwards to re-use the previously exported user keytabs

6. Ambari creates local system accounts on all servers. If nsswitch lists files first or there is an SSSD user/group ID resolution problem when doing the chown of the headless keytabs then the local account UIDs will be set instead. To avoid this try to pre-stage the local system accounts for ambari-qa/hdfs/hbase with the same UIDs across servers and set the FreeIPA UIDs for those user accounts to be the same.

Tested on HDP 2.1, Ambari 1.5/1.6.1, FreeIPA 3.0.0";

# Heavily leverages my personal library for lots of error checking

# No longer setting --random password and not longer having to deal with all the extra complexity of hacking the krbPasswordExpiration
#   - LDAP 'cn=Directory Manager' --password (optional) to remove immediate IPA expiry of new accounts for Hadoop smoke test users (ambari-qa, hdfs, hbase), otherwise you'll end up with service start failures 'kinit: Password has expired while getting initial credentials'
#   - /etc/ipa/ca.crt to verify LDAPS certificate on FreeIPA server (set up automatically by IPA client install)

$VERSION = "0.7.2";

use strict;
use warnings;
BEGIN {
    use File::Basename;
    use lib dirname(__FILE__) . "/lib";
}
use HariSekhonUtils qw/:DEFAULT :regex/;
use Data::Dumper;
use File::Copy;
use File::Glob  ':globally';
use File::Path  'make_path';
use File::Temp  ':POSIX'   ;
use Net::Domain 'hostfqdn' ;
#use Net::LDAPS;
#use Net::LDAP::Filter;
use POSIX;

$github_repo = "toolbox";

my $ipa_server;
#my $base_dn;
my $bind_dn;
my $bind_password;
#env_creds(["IPA_LDAP", "LDAP"], "LDAP");
env_vars("IPA_SERVER",        $ipa_server);
env_vars("IPA_BIND_DN",       $bind_dn);
env_vars("IPA_BIND_PASSWORD", $bind_password);

my $KINIT = "/usr/bin/kinit";
my $KLIST = "/usr/bin/klist";

my $IPA="/usr/bin/ipa";
my $IPA_GETKEYTAB="/usr/sbin/ipa-getkeytab";

# fake email makes sure we pass IPA user creation, FreeIPA is fussy about the email format and it's possible to use principals in Ambari such as LOCAL/LOCALDOMAIN that IPA will not allow.
# If this is not set it will try to use the principal without host component as the email address, which may or may not fail
my $EMAIL="admin\@hari.sekhon.com";

set_timeout_max(3600);
set_timeout_default(300);

my $csv;
my $my_fqdn = hostfqdn() or warn "unable to determine FQDN of this host (will ssh+rsync back to self since cannot differentiate from other hosts)";
#$ipa_server = $my_fqdn unless $ipa_server;
my @output;
$verbose = 1;
my $quiet;
my $export_service_keytabs;
my $deploy_keytabs;
my $ssh_key;
my $export_user_keytabs;

%options = (
    "f|file=s"          => [ \$csv,            "CSV file exported from Ambari 'Enable Security' containing the list of Kerberos principals and hosts" ],
    "s|server=s"        => [ \$ipa_server,     "IPA server to export the keytabs from via LDAP. Requires FQDN in order to validate the LDAP SSL certificate [would otherwise result in the error 'Simple bind failed' or 'SASL Bind failed...'] (default: localhost's fqdn => $my_fqdn, \$IPA_SERVER)" ],
    #"p|password=s"     => [ \$password,        "'cn=Directory Manager' password (required to reset the expiry on new user accounts, \$IPA_LDAP_PASSWORD, \$LDAP_PASSWORD, \$PASSWORD)" ],
    "d|bind-dn=s"       => [ \$bind_dn,         "IPA LDAP Bind DN (optional, \$IPA_BIND_DN)" ],
    "w|bind-password=s" => [ \$bind_password,   "IPA LDAP Bind password (optional, \$IPA_BIND_PASSWORD)" ],
    #"b|base-dn=s"      => [ \$base_dn,         "Base DN of FreeIPA LDAP (will try to determine it from --bind-dn, otherwise must be specified)" ],
    "export-service-keytabs=s" => [ \$export_service_keytabs, "Export service keytabs without prompting (yes/no). WARNING: will invalidate existing keytabs, you must --deploy-keytabs to keep your cluser working once you do this" ],
    "export-user-keytabs=s"    => [ \$export_user_keytabs,    "Export user keytabs without prompting (yes/no). Choose NO unless this is the very first cluster setup in this IPA realm to prevent invalidating the first cluster's smoketest accounts needed for service startups" ],
    "deploy-keytabs=s"  => [ \$deploy_keytabs,  "Deploy keytabs via rsync without prompting (yes/no). Will back up existing keytabs on the host if any are found just in case" ],
    "i|ssh-key=s"       => [ \$ssh_key,         "SSH private key to use to SSH the nodes as root (optional, will search for defaults ~/.ssh/id_dsa, ~/.ssh/id_ecdsa, ~/.ssh/id_rsa if not specified)" ],
    "q|quiet"           => [ \$quiet,           "Quiet mode" ],
);
splice @usage_order, 0, 0, qw/file server password bind-dn bind-password base-dn export-service-keytabs export-user-keytabs deploy-keytabs ssh-key quiet/;

get_options();

$verbose-- if $quiet;

$csv = validate_file($csv, 0, "Principals CSV");
$ipa_server = validate_host($ipa_server, "IPA");
isFqdn($ipa_server) or warn "WARNING: KDC host --server is not an FQDN, this may cause a SASL Bind error due to not validating the LDAP SSL certificate (may still work with straight LDAP credentials --bind-dn and --bind-password\n";
#if($ipa_server ne "localhost"){
#    vlog2 "checking IPA server has been given as an FQDN in order for successful bind with certificate validation";
#    $ipa_server  = validate_fqdn($ipa_server, "KDC");
#}
#$password = validate_password($password, "Directory Manager") if $password;
#$base_dn = validate_ldap_dn($base_dn, "base") if $base_dn;
$bind_dn = validate_ldap_dn($bind_dn, "IPA bind") if $bind_dn;
$bind_password = validate_password($bind_password, "ldap IPA bind") if $bind_password;
if(($bind_dn and not $bind_password) or ($bind_password and not $bind_dn)){
    usage "if specifying one must specify both of --bind-dn and --bind-password";
}
#if(not $base_dn and $password and $bind_dn and $bind_dn =~ /cn\s*=\s*accounts\s*,/){
#    vlog2 "attempting to determine base-dn from --bind-dn '$bind_dn'";
#    $base_dn = $bind_dn;
#    $base_dn =~ s/^.*cn\s*=\s*accounts\s*,//; # or die "unrecognized --bind-dn format (not under cn=accounts), couldn't determine base dn from it, please specify --base-dn manually";
#    vlog2 "determined base-dn to be '$base_dn'";
#}
sub parse_response($$;$){
    my $var_ref = shift;
    my $val     = shift;
    my $name    = shift() || "";
    $name = ( $name ? "--$name option" : "response" );
    $val  =~ /^\s*(?:y(?:es)?|n(?:o)?)?\s*$/i or die "$name invalid, must be 'yes' or 'no'\n";
    if($val =~ /^\s*y(?:es)?\s*$/i){
        $$var_ref = 1;
    } else {
        $$var_ref = 0;
    }
}

if(defined($export_service_keytabs)){
    parse_response(\$export_service_keytabs, $export_service_keytabs, "export-service-keytabs");
}
if(defined($export_user_keytabs)){
    parse_response(\$export_user_keytabs, $export_user_keytabs, "export-user-keytabs");
}
if(defined($deploy_keytabs)){
    parse_response(\$deploy_keytabs, $deploy_keytabs, "deploy-keytabs");
}
if(defined($ssh_key)){
    $ssh_key = validate_file($ssh_key, 0, "ssh private key");
    $ssh_key = "-i $ssh_key";
} else {
    $ssh_key = "";
}

vlog;
set_timeout();

$status = "OK";

( -f $KLIST ) or die "ERROR: couldn't find '$KLIST', make sure you have ipa-client installed (includes krb5-workstation)\n";

# simple check to see if we have a kerberos ticket in cache
cmd($KLIST, 1);
# Not going to kinit for user, they can do that themselves
#@output = cmd("$KLIST");
#vlog;
#
#my $found_princ = 0;
#foreach(@output){
#    /^Default principal:\s*$user/ and $found_princ++;
#}
#
#@output = cmd("$KINIT $user <<EOF\n$password\nEOF\n", 1) unless $found_princ;
#vlog;

my $timestamp = strftime("%F_%H%M%S", localtime);
my $keytab_backups = "keytab-backups-$timestamp";

my %ipa;

sub get_ipa_info(){
    foreach my $type (qw/host user service/){
        vlog "fetching IPA $type list";
        ( -f $IPA ) or die "ERROR: couldn't find '$IPA', make sure you have ipa-admintools installed\n";
        @output = cmd("$IPA $type-find", 1);
        foreach(@output){
            if(/^\s*Host\s+name:\s+(.+)\s*$/  or
               /^\s*User\s+login:\s+(.+)\s*$/ or
               /^\s*Principal:\s+(.+)\s*$/
              ){
                push(@{$ipa{$type}}, $1);
            }
        }
    }
    vlog;
}


sub parse_csv(){
    my @principals;
    # error handling is handled in my library function open_file()
    vlog "parsing CSV '$csv'";
    my $fh = open_file $csv;

    while (<$fh>){
        chomp;
        s/#.*$//;
        next if /^\s*$/;
        #(my $host, my $description, my $principal, my $keytab, my $keytab_dir, my $owner, my $group, my $perm) = split($_, 8);
        /^([^,]+?),([^,]+?),([^,]+?),([^,]+?),([^,]+?),([^,]+?),([^,]+?),([^,]+)$/ or die "ERROR: invalid CSV format detected on line $.: '$_' (expected 8 comma separated fields)\n";
        my $host        = $1;
        my $description = $2;
        my $principal   = $3;
        my $keytab      = $4;
        my $keytab_dir  = $5;
        my $owner       = $6;
        my $group       = $7;
        my $perm        = $8;
        ###
        $host =~ /^($host_regex)$/ or die "ERROR: invalid host '$host' (field 1) on line $.: '$_' - failed host regex validation\n";
        $host = $1;
        $description =~ /^([\w\s-]+)$/ or die "ERROR: invalid description '$description' (field 2) on line $.: '$_' - may only contain alphanumeric characters";
        $description = $1;
        $principal   =~ /^(($user_regex)(?:\/($host_regex))?\@($host_regex))$/ or die "ERROR: invalid/unrecognized principal format found on line $.: '$principal'\n";
        $principal   = $1;
        my $user     = $2;
        my $host_component = $3;
        if($host_component and $host_component ne $host){
            die "ERROR: host '$host' (field 1) and host component '$host_component' from principal '$principal' (field 3) do not match on line $.: '$_'\n"
        }
        my $domain = $4;
        $keytab =~ /^($filename_regex)$/ or die "ERROR: invalid keytab file name '$keytab' (field 4) on line $.: '$_' - failed regex validation\n";
        $keytab = $1;
        $keytab_dir =~ /^($filename_regex)$/ or die "ERROR: invalid keytab directory '$keytab_dir' (field 5) on line $.: '$_' - failed regex validation\n";
        $keytab_dir = $1;
        $owner =~ /^($user_regex)$/ or die "ERROR: invalid owner '$owner' (field 6) on line $.: '$_' - failed regex validation\n";
        $owner = $1;
        $group =~ /^($user_regex)$/ or die "ERROR: invalid group '$group' (field 7) on line $.: '$_' - failed regex validation\n";
        $group = $1;
        $perm =~ /^(0?\d{3})$/ or die "ERROR: invalid perm '$perm' (field 8) on line $.: '$_' - failed regex validation\n";
        $perm = $1;
        push(@principals, [$host, $description, $principal, $keytab, $keytab_dir, $owner, $group, $perm, $user, $domain]);
    }
    close $fh;
    vlog;
    return @principals;
}

sub create_principals(@){
    my @principals = @_;
    vlog "* Creating IPA Kerberos principals:\n";
#    my $ldaps;
#    my $ldap_result;
#    if($password){
#        $base_dn or usage "--base-dn could not be determined, must be set explicitly\n";
#        vlog "connecting to LDAPS service on $ipa_server";
#        $ldaps = Net::LDAPS->new($ipa_server,
#                                    'port'   => 636,
#                                    'verify' => 'require',
#                                    'cafile' => '/etc/ipa/ca.crt') or die "ERROR: failed to connect to ldaps://$ipa_server:636: $!. $@\n";
#        vlog "binding to LDAPS service on $ipa_server as 'cn=Directory Manager'";
#        my $ldap_result = $ldaps->bind('cn=Directory Manager', 'password' => $password);
#        vlog3 Dumper($ldap_result);
#        if($ldap_result->{'resultCode'} ne 0){
#            my $err = $ldap_result->{'errorMessage'};
#            $err = "invalid bind --password?" unless ($err);
#            die "ERROR: failed to bind to ldaps://$ipa_server:636 with bind dn 'cn=Directory Manager', result code " . $ldap_result->{'resultCode'} . ": $err\n";
#        }
#    }
    my %dup_princs;
    foreach(@principals){
        my ($host, $description, $principal, $keytab, $keytab_dir, $owner, $group, $perm, $user, $domain) = @{$_};
        my $email;
        if($EMAIL){
            $email = $EMAIL;
        } else {
            $email = "$user\@$domain";
        }
        if(defined($dup_princs{$principal})){
            warn "WARNING: duplicate principal '$principal' for host '$host' detected ($description), skipping create...\n" if $verbose >= 2;
            next;
        }
        $dup_princs{$principal} = 1;
        if($principal =~ /\//){
            if(not grep { $host eq $_ } @{$ipa{"host"}}){
                vlog "creating host '$host' in IPA system";
                cmd("$IPA host-add --force '$host'", 1);
                push(@{$ipa{"host"}}, $host);
            } else {
                vlog3 "IPA host '$host' already exists, skipping...";
            }
            if(not grep { $principal eq $_ } @{$ipa{"service"}}){
                vlog "creating host service principal '$principal'";
                cmd("$IPA service-add --force '$principal'", 1);
                push(@{$ipa{"service"}}, $principal);
            } else {
                vlog "service principal '$principal' already exists, skipping...";
            }
        } else {
            if(not grep { $user eq $_ } @{$ipa{"user"}}){
                vlog "creating user principal '$principal'";
                #cmd("$IPA user-add --first='$description' --last='$description' --displayname='$principal' --email='$email' --principal='$principal' --random '$user'", 1);
                cmd("$IPA user-add --first='$description' --last='$description' --displayname='$principal' --email='$email' --principal='$principal' '$user'", 1);
#                if($password){
#                    $base_dn or usage "base-dn could not be determined, please supply --base-dn explicitly\n";
#                    my $dn = "uid=$user,cn=users,cn=accounts,$base_dn";
#                    vlog "disabling password expiry for dn='$dn' for principal '$principal' to allow keytab to be used immediately";
#                    # krbPasswordExpiration
#                    # could also do this via ipa command, but admin doesn't have permission to modify this attribute
#                    # ipa user-mod --setattr='krbPasswordExpiration=20380101000000Z' hdfs
#                    # ipa: ERROR: Insufficient access: Insufficient 'write' privilege to the 'krbPasswordExpiration' attribute of entry 'uid=hdfs,cn=users,cn=accounts,dc=local'.
#                    $ldap_result = $ldaps->modify($dn, 'replace' => { 'krbPasswordExpiration' => ['20380101000000Z'] });
#                    if($ldap_result->{'resultCode'} ne 0){
#                        my $err = $ldap_result->{'errorMessage'};
#                        if($ldap_result->{'resultCode'} eq 32){
#                            $err .= " (wrong --base-dn?)";
#                        }
#                        die "ERROR: failed to replace krbPasswordExpiration attribute for principal '$principal', result code " . $ldap_result->{'resultCode'} . ": $err\n";
#                    }
#                    vlog3 Dumper($ldap_result) . "\n";
#                }
            } else {
                vlog "user principal '$principal' already exists, skipping...";
            }
        }
    }
    vlog;
}

sub export_keytabs(@){
    my @principals = @_;
    vlog "\n* Exporting IPA Kerberos keytabs from IPA server '$ipa_server' via LDAPS:\n";

    ( -f $IPA_GETKEYTAB ) or die "ERROR: couldn't find '$IPA_GETKEYTAB', make sure you have ipa-client installed (WARNING: this should have been caught earlier)\n";

    vlog "will backup any existing keytabs to sub-directory $keytab_backups at same location as originals\n";
    my %seen_princs;
    foreach(@principals){
        my ($host, $description, $principal, $keytab, $keytab_dir, $owner, $group, $perm) = @{$_};
        my $keytab_staging_dir = "$keytab_dir/$host";
        if(not $principal =~ /\//){
            unless($export_user_keytabs){
                vlog3 "not exporting user keytab for principal '$principal'";
                next;
            }
            $keytab_staging_dir = "$keytab_dir/users";
        } else {
            unless($export_service_keytabs){
                vlog3 "not exporting service keytab for principal '$principal'";
                next;
            }
        }
        if( -d "$keytab_staging_dir" ){
            #vlog2 "found keytab directory '$keytab_staging_dir'";
            ( -w "$keytab_staging_dir" ) or die "ERROR: keytab directory '$keytab_staging_dir' is not writeable!\n";
        } else {
            vlog "creating keytab directory '$keytab_staging_dir'";
            make_path("$keytab_staging_dir", "mode" => "0700") or die "ERROR: failed to create directory '$keytab_staging_dir': $!\n";
        }
        if(defined($seen_princs{$principal})){
            defined($seen_princs{$principal}{"keytab"}) or code_error "principal '$principal' has already been exported but it's keytab path wasn't recorded!";
            if($seen_princs{$principal}{"keytab"} eq "$keytab_staging_dir/$keytab"){
                ( -f $seen_princs{$principal}{"keytab"}) or die "previously exported keytab '$seen_princs{$principal}{keytab}' from seen principal not found!\n";
                vlog "skipping duplicate principal '$principal' and keytab '$keytab_staging_dir/$keytab'";# (matches existing '$seen_princs{$principal}{keytab}')";
            } else {
                vlog "copying keytab for principal '$principal' keytab '$keytab_staging_dir/$keytab' from already exported keytab '$seen_princs{$principal}{keytab}'"; # (to avoid resetting and invalidating the previously exported keytab)";
                copy($seen_princs{$principal}{"keytab"}, "$keytab_staging_dir/$keytab") or die "ERROR: failed to copy keytab '$seen_princs{$principal}{keytab}' => '$keytab_staging_dir/$keytab'\n";
            }
        } else {
            if(-f "$keytab_staging_dir/$keytab"){
                my $keytab_backup_dir = "$keytab_staging_dir/$keytab_backups";
                unless ( -d $keytab_backup_dir ){
                    make_path($keytab_backup_dir, "mode" => "0700") or die "ERROR: failed to create backup directory '$keytab_backup_dir': $!\n";
                }
                vlog2 "backing up existing keytab '$keytab_staging_dir/$keytab' => '$keytab_backup_dir/'";
                copy("$keytab_staging_dir/$keytab", "$keytab_backup_dir/") or die "ERROR: failed to back up existing keytab '$keytab_staging_dir/$keytab' => '$keytab_backup_dir/': $!";
            }
            my $tempfile = tmpnam();
            vlog "exporting keytab for principal '$principal' to '$keytab_staging_dir/$keytab'";
            my $cmd = "$IPA_GETKEYTAB -s '$ipa_server' -p '$principal' -k '$tempfile'";
            $cmd .= " -D '$bind_dn' -w '$bind_password'" if($bind_dn and $bind_password);
            @output = cmd($cmd, 1);
            move($tempfile, "$keytab_staging_dir/$keytab") or die "ERROR: failed to move temp file '$tempfile' to '$keytab_staging_dir/$keytab': $!";
            $seen_princs{$principal}{"keytab"} = "$keytab_staging_dir/$keytab";
        }
        my $uid = getpwnam $owner;
        my $gid = getgrnam $group;
        if(defined($uid)){
            if($uid < 209800000){
                vlog3 "owner $owner resolved to $uid, less than < 209800000 implies that this is the local user account UID and not the UID from the IPA user, this may cause permissions issues on host '$host' keytab '$keytab'\n";
            }
        } else {
            warn "WARNING: failed to resolve UID for user '$owner', defaulting to UID 0 for keytab '$keytab'\n" if($verbose >= 3);
            $uid = 0;
        }
        if(defined($gid)){
            if($gid < 209800000){
                vlog3 "group $group resolved to $gid, less than < 209800000 implies that this is the local group account GID and not the GID from the IPA group, this may cause permissions issues on host '$host' keytab '$keytab'\n";
            }
        } else {
            warn "WARNING: failed to resolve GID for group '$group', defaulting to GID 0 for keytab '$keytab'\n" if ($verbose >= 3);
            $gid = 0;
        }
        chown($uid, $gid, "$keytab_staging_dir/$keytab") or die "ERROR: failed to chown keytab '$keytab_staging_dir/$keytab' to $owner:$group ($uid:$gid) : $!\n";
        chmod($perm, "$keytab_staging_dir/$keytab") or die "ERROR: failed to chmod keytab '$keytab_staging_dir/$keytab' to $perm: $!\n";
    }
    vlog;
}

sub deploy_keytabs(@){
    my @principals = @_;
    vlog "\n* Deploying keytabs to hosts:\n";
    my %hosts;
    my $local_copy;
    foreach(@principals){
        my ($host, $description, $principal, $keytab, $keytab_dir, $owner, $group, $perm) = @{$_};
        # Would have like to have made this a global bulk but each keytab could theoretically have a different dir
        my $keytab_backup_dir = "$keytab_dir/$keytab_backups";
        my $keytab_staging_dir = "$keytab_dir/$host";
        my $principal_type = "service";
        $principal_type = "user" if($principal !~ /\//);
        $keytab_staging_dir = "$keytab_dir/users" if($principal !~ /\//);
        if($host eq $my_fqdn){
            if( -f "$keytab_dir/$keytab"){
                unless ( -d $keytab_backup_dir ){
                    make_path($keytab_backup_dir, "mode" => "0700") or die "ERROR: failed to create backup directory '$keytab_backup_dir': $!\n";
                }
                vlog3 "backing up existing keytab '$keytab_dir/$keytab' => '$keytab_backup_dir/'";
                copy("$keytab_dir/$keytab", "$keytab_backup_dir/") or die "ERROR: failed to back up existing keytab '$keytab_dir/$keytab' => '$keytab_backup_dir': $!";
            }
            ( -f "$keytab_staging_dir/$keytab" ) or die "keytab '$keytab' not found in '$keytab_staging_dir', did you skip exporting user or service keytabs?\n";
            vlog2 "copying locally '$keytab_staging_dir/$keytab' => '$keytab_dir/'";
            copy("$keytab_staging_dir/$keytab", "$keytab_dir/") or die "ERROR: failed to copy '$keytab_staging_dir/$keytab' => $keytab_dir/: $!\n";
            $local_copy = 1;
        } else {
            push(@{$hosts{$host}{$keytab_dir}}, $keytab);
        }
    }
    vlog "* Copied keytabs locally for $my_fqdn" if $local_copy;
    foreach my $host (sort keys %hosts){
        vlog "* Copying keytabs to host $host";
        foreach my $keytab_dir (sort keys %{$hosts{$host}}){
            ( -e $keytab_dir ) or die "keytab dir '$keytab_dir' does not exist, did you skip exporting keytabs?\n";
            ( -d $keytab_dir ) or die "keytab dir '$keytab_dir' is not a directory, unexpected condition, aborting\n";
            my $keytab_list;
            # iterating to check for each keytab's existence to catch when keytabs have not been previously exported
            #my $keytab_list = "'$keytab_dir/$host/" . join("' '$keytab_staging_dir/", @{$hosts{$host}{$keytab_dir}}) . "'";
            foreach my $keytab (@{$hosts{$host}{$keytab_dir}}){
                if( -f "$keytab_dir/$host/$keytab" ){
                    $keytab_list .= "'$keytab_dir/$host/$keytab' ";
                } elsif( -f "$keytab_dir/users/$keytab" ){
                    $keytab_list .= "'$keytab_dir/users/$keytab' ";
                } else {
                    die "keytab '$keytab' not found in '$keytab_dir/$host' or '$keytab_dir/users', did you skip exporting user or service keytabs?\n";
                }
            }
            my $keytab_backup_dir = "$keytab_dir/$keytab_backups";
            vlog2 "backing up any existing keytab in keytab dir '$keytab_dir' => '$keytab_backup_dir/' on host $host";
            cmd("ssh -oPreferredAuthentications=publickey $ssh_key root\@'$host' '
                set -e
                set -u
                set -x
                if [ -e \"$keytab_dir\" ]; then
                    if [ -d  \"$keytab_dir\" ]; then
                        if test -n \"\$(shopt -s nullglob; echo \"$keytab_dir/\"*.keytab)\"; then
                            echo \"Backing up remote keytabs on '$host' in dir $keytab_dir => $keytab_backup_dir/\"
                            mkdir -v \"$keytab_backup_dir\"
                            for x in $keytab_dir/*.keytab; do
                                cp -av \"\$x\" \"$keytab_backup_dir/\" || exit 1
                            done
                        fi
                    else
                        echo \"ERROR: $keytab_dir is not a directory\"
                        exit 1
                    fi
                fi' ", 1);
            vlog2 "copying keytabs to '$keytab_dir/' on host $host";
            cmd("rsync -av -e 'ssh -o PreferredAuthentications=publickey $ssh_key' $keytab_list root\@'$host':'$keytab_dir/' ", 1);
        }
    }
    vlog;
}

sub ask($$){
    my $var_ref  = shift;
    my $question = shift;
    unless(defined($$var_ref)){
        print "\n$question? (y/N) ";
        my $response = <STDIN>;
        chomp $response;
        vlog;
        parse_response($var_ref, $response);
    }
}

sub main(){
    my @principals = parse_csv();
    get_ipa_info();
    create_principals @principals;

    ask(\$export_service_keytabs, "About to export keytabs:

WARNING: re-exporting keytabs will invalidate all currently existing keytabs for these principals and you MUST re-deploy the newly exported keytabs.

Do you want to export service keytabs");
    ask(\$export_user_keytabs, "User keytabs are shared across clusters in an IPA realm. Only export them for the first initial cluster setup or when adding a service (in which case the source CSV must contain only the new service principals). Say NO when adding hosts to an existing cluster or deploying 2nd cluster in same IPA realm.

Do you want to export user keytabs");

    if($export_service_keytabs or $export_user_keytabs){
        export_keytabs(@principals);
    } else {
        print "\nnot exporting keytabs\n";
    }

    ask(\$deploy_keytabs, "Would you like to deploy keytabs to hosts");

    if($deploy_keytabs){
        deploy_keytabs(@principals);
    } else {
        print "\nnot deploying keytabs\n";
    }
    print "\nComplete\n";
}

main();
exit 0;
