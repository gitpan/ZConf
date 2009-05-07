package ZConf;

use Net::LDAP;
use Net::LDAP::Express;
use Net::LDAP::LDAPhash;
use Net::LDAP::Makepath;
use File::Path;
use File::BaseDir qw/xdg_config_home/;
use Chooser;
use warnings;
use strict;
use ZML;

=head1 NAME

ZConf - A configuration system allowing for either file or LDAP backed storage.

=head1 VERSION

Version 1.1.1

=cut

our $VERSION = '1.1.1';

=head1 SYNOPSIS

This is currently mostly done and is largely being released as I want to get to writing 
some small desktop apps using it. Still needing implementation is fall through
on error, syncing between backends, and listing of configs.

    use ZConf;

	#creates a new instance
    my $zconf = ZConf->new();
    ...

=head1 FUNCTIONS

=head2 new

	my $zconf=ZCnf->(%args);

This initiates the ZConf object. If it can't be initiated, a value of undef
is returned. The hash can contain various initization options.

When it is run for the first time, it creates a filesystem only config file.

=head3 args hash

=head4 file

The default is 'xdf_config_home/zconf.zml', which is generally '~/.config/zconf.zml'.

This is incompatible with the sys option.

=head4 sys

This turns system mode on. And sets it to the specified system name.

This is incompatible with the file option.

    my $zconf=ZConf->new();
    if((!defined($zconf)) || ($zconf->{error})){
        print "Error!\n";
    }

=cut

#create it...
sub new {
	my %args;
	if(defined($_[1])){
		%args= %{$_[1]};
	};

	#The thing that will be returned.
	#conf holds configs
	#args holds the arguements passed to new as well as runtime parameters
	#set contains what set is in use for any loaded config
	#zconf contains the parsed contents of zconf.zml
	#user is space reserved for what ever the user of this package may wish to
	#     use it for... if they ever find the need to or etc... reserved for
	#     the prevention of poeple shoving stuff into $self->{} where ever
	#     they please... probally some one still will... but this is intented
	#     to help minimize it...
	#error this is undef if, otherwise it is a integer for the error in question
	#errorString this is a string describing the error
	my $self = {conf=>{}, args=>{%args}, set=>{}, zconf=>{}, user=>{}, error=>undef,
				errorString=>""};
	bless $self;

	if (defined($self->{args}{file}) && defined($self->{args}{sysmode})) {
		warn('ZConf new:35: sys and file can not be specified together');
		$self->{error}=35;
		$self->{errorString}='sys and file can not be specified together';
		return undef;
	}

	#sets the base directory
	if (!defined($self->{args}{sys})) {
		$self->{args}{base}=xdg_config_home()."/zconf/";
	}else {
		$self->{args}{base}=$self->{args}{sys}."/zconf/";
	}

	#set the config file if it is not already set
	if(!defined($self->{args}{file})){
		$self->{args}{file}=$self->{args}{base}."/zconf.zml";
		#Make the config file if it does not exist.
		#We don't create it if it is manually specified as we assume
		#that the caller manually specified it for some reason.
		if(!-f $self->{args}{file}){
			if(open("CREATECONFIG", '>', $self->{args}{file})){
				print CREATECONFIG "fileonly=1\nreadfallthrough=1\n";
				close("CREATECONFIG");
			}else{
				print "zconf new error: '".$self->{args}{file}."' could not be opened.\n";
				return undef;
			};
		};
	};

	#do something if the base directory does not exist
	if(! -d $self->{args}{base}){
		#if the base diretory can not be created, exit
		if(!mkdir($self->{args}{base})){
			print "zconf new error: '".$self->{args}{base}.
			      "' does not exist and could not be created.\n";
			return undef;
		};		
	};

	my $zconfzmlstring="";#holds the contents of zconf.zml
	#returns undef if it can't read zconf.zml
	if(open("READZCONFZML", $self->{args}{file})){
		$zconfzmlstring=join("", <READZCONFZML>);
		my $tempstring;
		close("READZCONFZML");
	}else{
		print "zconf new error: Could not open'".$self->{args}{file}."\n";
		return undef;
	};

	#tries to parse the zconf.zml
	my $zml=ZML->new();
	$zml->parse($zconfzmlstring);
	if($zml->{error}){
		warn("ZConf new:28: ZML->parse error, '".$zml->{error}."', '".$zml->{errorString}."'.");
		return undef;
	};
	$self->{zconf}=$zml->{var};

	#if defaultChooser is defined, use it to find what the default should be
	if(defined($self->{zconf}{defaultChooser})){
		#runs choose if it is defined
		my ($success, $choosen)=choose($self->{zconf}{defaultChooser});
		if($success){
			#check if the choosen has a legit name
			#if it does not, set it to default
			if(setNameLegit($choosen)){
				$self->{args}{default}=$choosen;
			}else{
				$self->{args}{default}="default";
			};
		}else{
			$self->{args}{default}="default";
		};
	}else{
		if(defined($self->{zconf}{default})){
			$self->{args}{default}=$self->{zconf}{default};
		}else{
			$self->{args}{default}="default";
		};
	};
		
	#get what the file only arg should be
	#this is a Perl boolean value
	if(!defined($self->{zconf}{fileonly})){
		$self->{zconf}->{args}{fileonly}="0";
	}else{
		$self->{args}{fileonly}=$self->{zconf}{fileonly};
	};

	if($self->{args}{fileonly} eq "0"){
		#gets what the backend should be using backendChooser
		#if not defined, check for backend and if that is not
		#defined, just use the file backend
		if(defined($self->{zconf}{backendChooser})){
			my ($success, $choosen)=choose($self->{zconf}{backendChooser});
			if($success){
				$self->{args}{backend}=$choosen;
			}else{
				if(defined{$self->{zconf}{backend}}){
					$self->{args}{backend}=$self->{zconf}{backend};
				}else{
					$self->{args}{backend}="file";
				};				
			};
		}else{
			if(defined($self->{zconf}{backend})){
				$self->{args}{backend}=$self->{zconf}{backend};
			}else{
				$self->{args}{backend}="file";
			};
		};
	}else{
		$self->{args}{backend}="file";
	};
		
	#make sure the backend is legit
	my @backends=("file", "ldap");
	my $backendLegit=0;
	my $backendsInt=0;
	while(defined($backends[$backendsInt])){
		if ($backends[$backendsInt] eq $self->{args}{backend}){
			$backendLegit=1;
		};

		$backendsInt++;
	};

	if(!$backendLegit){
		warn("zconf new error: The backend '".$self->{args}{backend}.
			 "' is not a recognized backend.\n");
		return undef;
	};
		
	#real in the LDAP settings
	if($self->{args}{backend} eq "ldap"){
		#figures out what profile to use
		if(defined($self->{zconf}{LDAPprofileChooser})){
			#run the chooser to get the LDAP profile to use
			my ($success, $choosen)=choose($self->{zconf}{LDAPprofileChooser});
			#if the chooser fails, set the profile to default
			if(!$success){
				$self->{args}{LDAPprofile}="default";
			}else{
				$self->{args}{LDAPprofile}=$choosen;
			};
		}else{
			#if LDAPprofile is defined, use it, if not set it to default
			if(defined($self->{zconf}{LDAPprofile})){
				$self->{args}{LDAPprofile}=$self->{zconf}{LDAPprofile};
			}else{
				$self->{args}{LDAPprofile}="default";
			};
		};

		#gets the host
		if(defined($self->{zconf}{"ldap/".$self->{args}{LDAPprofile}."/host"})){
			$self->{args}{"ldap/host"}=$self->{zconf}{"ldap/".$self->{args}{LDAPprofile}."/host"};
		}else{
			#sets it to localhost if not defined
			$self->{args}{"ldap/host"}="127.0.0.1"
		};

		#gets the host
		if(defined($self->{zconf}{"ldap/".$self->{args}{LDAPprofile}."/password"})){
			$self->{args}{"ldap/password"}=$self->{zconf}{"ldap/".$self->{args}{LDAPprofile}."/password"};
		}else{
			#sets it to localhost if not defined
			$self->{args}{"ldap/password"}="";
		};

		#gets bind to use
		if(defined($self->{zconf}{"ldap/".$self->{args}{LDAPprofile}."/bind"})){
			$self->{args}{"ldap/bind"}=$self->{zconf}{"ldap/".$self->{args}{LDAPprofile}."/bind"};
		}else{
			$self->{args}{"ldap/bind"}=`hostname`;
			chomp($self->{args}{"ldap/bind"});
			#the next three lines can result in double comas.
			$self->{args}{"ldap/bind"}=~s/^.*\././ ;
			$self->{args}{"ldap/bind"}=~s/\./,dc=/g ;
			$self->{args}{"ldap/bind"}="uid=".$ENV{USER}.",ou=users,".$self->{args}{"ldap/bind"};
			#remove any double comas if they crop up
			$self->{args}{"ldap/bind"}=~s/,,/,/g;
		};

		#gets bind to use
		if(defined($self->{zconf}{"ldap/".$self->{args}{LDAPprofile}."/homeDN"})){
			$self->{args}{"ldap/homeDN"}=$self->{zconf}{"ldap/".$self->{args}{LDAPprofile}."/homeDN"};
		}else{
			$self->{args}{"ldap/homeDN"}=`hostname`;
			chomp($self->{args}{"ldap/bind"});
			#the next three lines can result in double comas.
			$self->{args}{"ldap/homeDN"}=~s/^.*\././ ;
			$self->{args}{"ldap/homeDN"}=~s/\./,dc=/g ;
			$self->{args}{"ldap/homeDN"}="ou=".$ENV{USER}.",ou=home,".$self->{args}{"ldap/bind"};
			#remove any double comas if they crop up
			$self->{args}{"ldap/homeDN"}=~s/,,/,/g;
		};

		#this holds the DN that is the base for everything done
		$self->{args}{"ldap/base"}="ou=zconf,ou=.config,".$self->{args}{"ldap/homeDN"};
		
		#tests the connection
		my $ldap;
		eval {
   			$ldap =
				Net::LDAP::Express->new(host => $self->{args}{"ldap/host"},
				bindDN => $self->{args}{"ldap/bind"},
				bindpw => $self->{args}{"ldap/password"},
				base   => $self->{args}{"ldap/homeDN"},
				searchattrs => [qw(dn)]);
		} ;
		if($@){
			warn("zconf ldap init error:".$@);
		};

		#tests if "ou=.config,".$self->{args}{"ldap/homeDN"} exists or nnot...
		#if it does not, try to create it...
		my $ldapmesg=$ldap->search(scope=>"base", base=>"ou=.config,".$self->{args}{"ldap/homeDN"},
								filter => "(objectClass=*)");
		my %hashedmesg=LDAPhash($ldapmesg);
		if(!defined($hashedmesg{"ou=.config,".$self->{args}{"ldap/homeDN"}})){
			my $entry = Net::LDAP::Entry->new();
			$entry->dn("ou=.config,".$self->{args}{"ldap/homeDN"});
			$entry->add(objectClass => [ "top", "organizationalUnit" ], ou=>".config");
			my $result = $ldap->update($entry);
			if($ldap->error()){
		    	warn("zconf ldap init error: ".$self->{args}{"ldap/base"}." ".$ldap->error.
         				"; code ",$ldap->errcode);
       			return undef;
			};
		};

		#tests if "ldap/base" exists... try to create it if it does not
		$ldapmesg=$ldap->search(scope=>"base", base=>$self->{args}{"ldap/base"},filter => "(objectClass=*)");
		%hashedmesg=LDAPhash($ldapmesg);
		if(!defined($hashedmesg{$self->{args}{"ldap/base"}})){
			my $entry = Net::LDAP::Entry->new();
			$entry->dn($self->{args}{"ldap/base"});
			$entry->add(objectClass => [ "top", "organizationalUnit" ], ou=>"zconf");
			my $result = $ldap->update($entry);
			if($ldap->error()){
		    	warn("zconf ldap init error: ".$self->{args}{"ldap/base"}." ".$ldap->error.
         				"; code ",$ldap->errcode);
       			return undef;
			};
		};
		
		#disconnects from the LDAP server
		$ldap->unbind;
	};

	return $self;
};

=head2 chooseSet

This chooses what set should be used using the associated chooser
string for the config in question.

This function does fail safely. If a improper configuration is returned by
chooser string, it uses the value the default set.

It takes one arguement, which is the configuration it is for.

	my $set=$zconf->chooseSet("foo/bar")

=cut

#the overarching function for getting available sets
sub chooseSet{
	my ($self, $config) = @_;

	$self->errorBlank;

	my ($error, $errorString)=$self->configNameCheck($config);
	if(defined($error)){
		warn("zconf chooseSet:".$error.": ".$errorString);
		$self->{error}=$error;
		$self->{errorString}=$errorString;
		return undef;
	};


	my $chooserstring=$self->readChooser($config);
	
	my ($success, $choosen)=choose($chooserstring);
	
	if(!defined($choosen)){
		return $self->{args}{default};
	};
	
	if (!$self->setNameLegit($choosen)){
		warn("zconf chooseSet:27: '".$choosen."' is not a legit set name. Using the".
				" default of '".$self->{args}{default}."'.");
		return $self->{args}{default};
	};
	
	return $choosen;
};

=head2 config2dn

This function converts the config name into part of a DN string. IT
is largely only for internal use and is used by the LDAP backend.

	my $partialDN = $zconf->config2dn("foo/bar");

=cut

#converts the config to a DN
sub config2dn(){
	my $self=$_[0];
	my $config=$_[1];

	$self->errorBlank;

	if ($config eq '') {
		return '';
	}

	my ($error, $errorString)=$self->configNameCheck($config);
	if(defined($error)){
		warn("zconf config2dn:".$error.": ".$errorString);
		$self->{error}=$error;
		$self->{errorString}=$errorString;
		return undef;
	};

	#splits the config at every /
	my @configSplit=split(/\//, $config);

	my $dn=undef; #stores the DN

	my $int=0; #used for intering through @configSplit
	#does the conversion
	while(defined($configSplit[$int])){
		if(defined($dn)){
			$dn="cn=".$configSplit[$int].",".$dn;
		}else{
			$dn="cn=".$configSplit[$int];
		};
			
		$int++;
	};
		
	return $dn;
};

=head2 configExists 

This function is used for checking if a config exists or not.

It takes one option, which is the configuration to check for.

The returned value is a perl boolean value.

	if(!$zconf->configExists("foo/bar")){
		print "'foo/bar' does not exist\n";
	};

	#does the same thing above, but using the error interface
	my $returned = $zconf->configExists("foo/bar")
	if(defined($zconf->{error})){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	};

=cut

#check if a config exists
sub configExists{
	my ($self, $config) = @_;

	$self->errorBlank;

	my ($error, $errorString)=$self->configNameCheck($config);
	if(defined($error)){
		warn("zconf configExists:".$error.": ".$errorString);
		$self->{error}=$error;
		$self->{errorString}=$errorString;
		return undef;
	};

	my $returned=undef;

	#run the checks
	if($self->{args}{backend} eq "file"){
		$returned=$self->configExistsFile($config);
	}else{
		if($self->{args}{backend} eq "ldap"){
			$returned=$self->configExistsLDAP($config);
		};
		#if it errors and read fall through is turned on, try the file backend
		if ($self->{error}&&$self->{args}{readfallthrough}) {
			$self->errorBlank;
			$returned=$self->configExistsFile($config);
		}
	};

	if(!$returned){
		return undef;
	};

	return 1;		
};

=head2 configExistsFile

This function functions exactly the same as configExists, but
for the file backend.

No config name checking is done to verify if it is a legit name or not
as that is done in configExists. The same is true for calling errorBlank.

	if(!$zconf->configExistsFile("foo/bar")){
		print "'foo/bar' does not exist\n";
	};

	#does the same thing above, but using the error interface
	my $returned = $zconf->configExistsFile("foo/bar")
	if(defined($zconf->{error})){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	};

=cut

#checks if a file config exists 
sub configExistsFile{
	my ($self, $config) = @_;

	#makes the path if it does not exist
	if(!-d $self->{args}{base}."/".$config){
		return 0;
	};
		
	return 1;
};

=head2 configExistsLDAP

This function functions exactly the same as configExists, but
for the LDAP backend.

No config name checking is done to verify if it is a legit name or not
as that is done in configExists. The same is true for calling errorBlank.

	if(!$zconf->configExistsLDAP("foo/bar")){
		print "'foo/bar' does not exist\n";
	};

	#does the same thing above, but using the error interface
	my $returned = $zconf->configExistsLDAP("foo/bar")
	if($zconf->{error}){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	};

=cut

#check if a LDAP config exists
sub configExistsLDAP{
	my ($self, $config) = @_;

	my @lastitemA=split(/\//, $config);
	my $lastitem=$lastitemA[$#lastitemA];

	#gets the LDAP message
	my $ldapmesg=$self->LDAPgetConfMessage($config);
	#return upon error
	if (defined($self->{error})) {
		return undef;
	}

	my %hashedmesg=LDAPhash($ldapmesg);
#	$ldap->unbind;
	my $dn=$self->config2dn($config);
	$dn=$dn.",".$self->{args}{"ldap/base"};

	if(!defined($hashedmesg{$dn})){
		return undef;
	};

	return 1;
};

=head2 configNameCheck

This checks if the name of a config is legit or not. See the section
CONFIG NAME for more info on config naming.

	my ($error, $errorString) = $zconf->configNameCheck($config);
	if(defined($error)){
		warn("zconf configExists:".$error.": ".$errorString);
		$self->{error}=$error;
		$self->{errorString}=$errorString;
		return undef;
	};

=cut

#checks the config name
sub configNameCheck{
	my ($self, $name) = @_;

	#checks for undef
	if(!defined($name)){
		return("11", "config name is not defined.");
	};

	#checks for ,
	if($name =~ /,/){
		return("1", "config name,'".$name."', contains ','");
	};

	#checks for /.
	if($name =~ /\/\./){
		return("2", "config name,'".$name."', contains '/.'");
	};

	#checks for //
	if($name =~ /\/\//){
		return("3", "config name,'".$name."', contains '//'");
	};

	#checks for ../
	if($name =~ /\.\.\//){
		return("4", "config name,'".$name."', contains '../'");
	};

	#checks for /..
	if($name =~ /\/\.\./){
		return("5", "config name,'".$name."', contains '/..'");
	};

	#checks for ^./
	if($name =~ /^\.\//){
		return("6", "config name,'".$name."', matched /^\.\//");
	};

	#checks for /$
	if($name =~ /\/$/){
		return("7", "config name,'".$name."', matched /\/$/");
	};

	#checks for ^/
	if($name =~ /^\//){
		return("8", "config name,'".$name."', matched /^\//");
	};

	#checks for ^/
	if($name =~ /\n/){
		return("10", "config name,'".$name."', matched /\\n/");
	};

	return(undef, "");
};

=head2 createConfig

This function is used for creating a new config. 

One arguement is needed and that is the config name.

The returned value is a perl boolean.

	if(!$zconf->createConfig("foo/bar")){
		print "'foo/bar' could not be created\n";
	};

	#does the same thing above, but using the error interface
	my $returned = $zconf->createConfig("foo/bar")
	if(defined($zconf->{error})){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	};

=cut

#the overarching function for getting available sets
sub createConfig{
	my ($self, $config) = @_;

	my ($error, $errorString)=$self->configNameCheck($config);
	if(defined($error)){
		warn("zconf createConfig:".$error.": ".$errorString);
		$self->{error}=$error;
		$self->{errorString}=$errorString;
		return undef;
	};

	my $returned=undef;

	#create the config
	if($self->{args}{backend} eq "file"){
		$returned=$self->createConfigFile($config);
	}else{
		if($self->{args}{backend} eq "ldap"){
			$returned=$self->createConfigLDAP($config);
		};
	};

	if(!$returned){
		return undef;
	};

	#attempt to sync the config locally if not using the file backend
	if($self->{args}{backend} ne "file"){
		#if it does not exist, add it
		if(!$self->configExistsFile($config)){
			my $syncReturn=$self->createConfigFile($config);
			if (!$syncReturn){
				warn("zconf createConfig:10: Syncing to file failed for '".$config."'.");
				$self->{error}=10;
				$self->{errorString}="zconf createConfig: Syncing to file failed for '".$config."'.";
			};
		};
	};

	return 1;
};

=head2 createConfigFile

This functions just like createConfig, but is for the file backend.
This is not really meant for external use. The config name passed
is not checked to see if it is legit or not.

	if(!$zconf->createConfigFile("foo/bar")){
		print "'foo/bar' could not be created\n";
	};

	#does the same thing above, but using the error interface
	my $returned = $zconf->createConfigFile("foo/bar")
	if(defined($zconf->{error})){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	};

=cut

#creates a new config file as well as the default set
sub createConfigFile{
	my ($self, $config) = @_;

	$self->errorBlank;

	#makes the path if it does not exist
	if(!mkpath($self->{args}{base}."/".$config)){
		warn("zconf createConfigFile:16: '".$self->{args}{base}."/".$config."' creation failed.");
		$self->{error}=16;
		$self->{errorString}="'".$self->{args}{base}."/".$config."' creation failed.";
		return undef;
	};

#commented out for now...
#as it currently stands the user has to initialize it		
		#creates the default set
#		if(open("NewConfig", '>', $self->{args}{base}."/".$config."/default")){
#			print NewConfig "";
#			close("NewConfig");
#			return 1;
#		}else{
#			warn("zconf createConfigFile:17: '".$self->{args}{base}."/".$config."' write failed.");
#			$self->{error}=17;
#			$self->{errorString}="'".$self->{args}{base}."/".$config."' write failed.";
#		};

	return 1;
};

=head2 createConfigLDAP

This functions just like createConfig, but is for the LDAP backend.
This is not really meant for external use. The config name passed
is not checked to see if it is legit or not.

	if(!$zconf->createConfigLDAP("foo/bar")){
		print "'foo/bar' could not be created\n";
	};

	#does the same thing above, but using the error interface
	my $returned = $zconf->createConfigLDAP("foo/bar")
	if(defined($zconf->{error})){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	};

=cut

#creates a new LDAP enty if it is not defined
sub createConfigLDAP{
	my ($self, $config) = @_;

	#converts the config name to a DN
	my $dn=$self->config2dn($config).",".$self->{args}{"ldap/base"};

	my @lastitemA=split(/\//, $config);
	my $lastitem=$lastitemA[$#lastitemA];

	#connects up to LDAP
	my $ldap=$self->LDAPconnect();
	if (defined($self->{error})) {
		warn('zconf createConfigLDAP: LDAPconnect errored... returning');
		return undef;
	}

	#gets the LDAP message
	my $ldapmesg=$self->LDAPgetConfMessage($config, $ldap);
	#return upon error
	if (defined($self->{error})) {
		return undef;
	}

	my %hashedmesg=LDAPhash($ldapmesg);
	if(!defined($hashedmesg{$dn})){
		my $path=$config; #used with for with LDAPmakepathSimple
		$path=~s/\//,/g; #converts the / into , as required by LDAPmakepathSimple
		my $returned=LDAPmakepathSimple($ldap, ["top", "zconf"], "cn",
					$path, $self->{args}{"ldap/base"});
		if(!$returned){
			warn("zconf createConfigLDAP:22: Adding '".$dn."' failed when executing LDAPmakepathSimple.");
			$self->{errorString}="zconf createLDAPConfig:22: Adding '".$dn."' failed when executing LDAPmakepathSimple.\n";
			$self->{error}=22;
			return undef;
		};
	}else{
		warn("zconf createLDAPConfig:11: DN '".$dn."' already exists.");
		$self->{error}=11;
		$self->{errorString}=" DN '".$dn."' already exists.";
		return undef;

	};
	return 1;
};



=head2 defaultSetExists

This checks to if the default set for a config exists. It takes one arguement,
which is the name of the config. The returned value is a Perl boolean.

=cut

sub defaultSetExists{
	my $self=$_[0];
	my $config=$_[1];

	$self->errorBlank();

	#make sure the config name is legit
	my ($error, $errorString)=$self->configNameCheck($config);
	if(defined($error)){
		warn("ZConf defaultSetExists:".$error.": ".$errorString);
		$self->{error}=$error;
		$self->{errorString}=$errorString;
		return undef;
	};

	#makes sure it exists
	if (!$self->configExists($config)){
		warn('ZConf defaultSetExists:12: The specified config, "'.$config.'" does not exist');
		return undef;
	}

	#figures out what to use for the set
	my $set=$self->chooseSet($config);
	if (defined($self->{error})){
		return undef;
	}

	#get the available sets to check if the default exists
	my @sets=$self->getAvailableSets($config);
	if ($self->{error}) {
		warn('ZConf defaultSetExists: getAvailableSets errored');
		return undef;
	}

	#check for one that matches...
	my $int=0;
	while (defined($sets[$int])) {
		if ($set eq $sets[$int]) {
			return 1;
		}
		$int++;
	}

	return undef;
}

=head2 delConfig

This removes a config. Any sub configs will need to removes first. If any are
present, this function will error.

    #removes 'foo/bar'
    $zconf->delConfig('foo/bar');
    if(defined($zconf->{error})){
        print 'error!';
    }

=cut

sub delConfig{
	my $self=$_[0];
	my $config=$_[1];

	$self->errorBlank;
	
	#return if no set is given
	if (!defined($config)){
		warn("zconf delConfig:25: \$config is not defined");
		$self->{error}=25;
		$self->{errorString}='$config not defined';
		return undef;
	};

	#makes sure no subconfigs exist
	my @subs=$self->getSubConfigs($config);
	#return if this can't be completed
	if (defined($self->{error})) {
		return undef;		
	}
	if (defined($subs[0])) {
		warn('ZConf delConfig:33: Could not remove the config as it has sub configs');
		$self->{error}=33;
		$self->{errorString}='Could not remove the config as it has sub configs.';
		return undef;
	}

	#do it
	my $returned;
	if($self->{args}{backend} eq "file"){
		$returned=$self->delConfigFile($config);
	}else{
		if($self->{args}{backend} eq "ldap"){
			$returned=$self->delConfigLDAP($config);
		}
	}

	if ($self->{args}{backend} ne "file") {
		$returned=$self->delConfigFile($config);
	}

	return $returned;
}

=head2 delConfigFile

This removes a config. Any sub configs will need to removes first. If any are
present, this function will error.

    #removes 'foo/bar'
    $zconf->delConfig('foo/bar');
    if(defined($zconf->{error})){
        print 'error!';
    }

=cut

sub delConfigFile{
	my $self=$_[0];
	my $config=$_[1];

	#return if this can't be completed
	if (defined($self->{error})) {
		return undef;		
	}

	my @subs=$self->getSubConfigsFile($config);
	#return if there are any sub configs
	if (defined($subs[0])) {
		warn('zconf delConfigFile:33: Could not remove the config as it has sub configs');
		$self->{error}='33';
		$self->{errorString}='Could not remove the config as it has sub configs';
		return undef;
	}

	#makes sure it exists before continuing
	#This will also make sure the config exists.
	my $returned = $self->configExistsFile($config);
	if (defined($self->{error})){
		warn('ZConf delConfigFile:12: The config, "'.$config.'", does not exist');
		$self->{error}='12';
		$self->{errorString}='The config, "'.$config.'", does not exist';
		return undef;
	}

	my @sets=$self->getAvailableSetsFile($config);
	if (defined($self->{error})) {
		warn('zconf delConfigFile: getAvailableSetsFile set an error');
		return undef;
	}

	#goes through and removes each set before deleting
	my $setsInt='0';#used for intering through @sets
	while (defined($sets[$setsInt])) {
		#removes a set
		$self->delSetFile($config, $sets[$setsInt]);
		if ($self->{error}) {
			warn('zconf delConfigFile: delSetFileset an error');
			return undef;
		}
		$setsInt++;
	}

	#the path to the config
	my $configpath=$self->{args}{base}."/".$config;

	if (!rmdir($configpath)) {
		warn('zconf delConfigFile:29: "'.$configpath.'" could not be unlinked');
		$self->{error}=29;
		$self->{errorString}='"'.$configpath.'" could not be unlinked.';
		return undef;
	}

	return 1;
}

=head2 delConfigLDAP

This removes a config. Any sub configs will need to removes first. If any are
present, this function will error.

    #removes 'foo/bar'
    $zconf->delConfig('foo/bar');
    if(defined($zconf->{error})){
        print 'error!';
    }

=cut

sub delConfigLDAP{
	my $self=$_[0];
	my $config=$_[1];

	my @subs=$self->getSubConfigsFile($config);
	#return if there are any sub configs
	if (defined($subs[0])) {
		warn('zconf delConfigLDAP:33: Could not remove the config as it has sub configs');
		$self->{error}='33';
		$self->{errorString}='Could not remove the config as it has sub configs';
		return undef;
	}

	#makes sure it exists before continuing
	#This will also make sure the config exists.
	my $returned = $self->configExistsLDAP($config);
	if (defined($self->{error})){
		warn('ZConf delConfigLDAP:12: The config, "'.$config.'", does not exist');
		$self->{error}='12';
		$self->{errorString}='The config, "'.$config.'", does not exist';
		return undef;
	}

	#connects up to LDAP... will be used later
	my $ldap=$self->LDAPconnect();
	
	#gets the DN and use $ldap since it is already setup
	my $entry=$self->LDAPgetConfEntry($config, $ldap);

	#if $entry is undefined, it was not found
	if (!defined($entry)){
		warn('zconf delConfigLDAP:13: The expected DN was not found');
		$self->{error}='13';
		$self->{errorString}='The expected DN was not found';
		return undef;
	}

	#remove it
	$entry->delete();
	$entry->update($ldap);

	#return if it could not be removed
	if($ldap->error()){
		warn('zconf delConfigLDAP:34: Could not delete the LDAP entry, "'.
			 $entry->dn().'". LDAP return an error of "'.$ldap->error.'" and an'.
			 'error code of "'.$ldap->errcode.'"');
		$self->{error}='34';
		$self->{errorString}=' Could not delete the LDAP entry, "'.
							$entry->dn().'". LDAP return an error of "'.$ldap->error.
							'" and an error code of "'.$ldap->errcode.'"';

		return undef;
	}

	return 1;
}

=head2 delSet

This deletes a specified set.

Two arguements are required. The first one is the name of the config and the and
the second is the name of the set.

    if(!$zconf->delSet("foo/bar", "someset")){
        print "delSet failed\n";
    }
    
    #does the same, but using the zconf error reporting method
    $zconf->delSetFile("foo/bar", "someset");
    if(defined($zconf->{error})){
        print "delSet failed\n";
    }

=cut

sub delSet{
	my $self=$_[0];
	my $config=$_[1];
	my $set=$_[2];
	
	$self->errorBlank;

	#return if no set is given
	if (!defined($set)){
		warn("zconf delSet:24: \$set is not defined");
		$self->{error}=24;
		$self->{errorString}='$set not defined';
		return undef;
	};

	#return if no config is given
	if (!defined($config)){
		warn("zconf delSet:25: \$config is not defined");
		$self->{error}=25;
		$self->{errorString}='$config not defined';
		return undef;
	}

	#makes sure it exists before continuing
	#This will also make sure the config exists.
	my $returned = $self->configExists($config);
	if (defined($self->{error})){
		warn('ZConf delSet:12: The config "'.$config.'" does not exist');
		return undef;
	}

	#do it
	if($self->{args}{backend} eq "file"){
		$returned=$self->delSetFile($config, $set);
	}else{
		if($self->{args}{backend} eq "ldap"){
			$returned=$self->delSetLDAP($config, $set);
		}
	}

	if (!$self->{args}{backend} eq "file") {
		$returned=$self->delSetFile($config, $set);
	}

	return $returned;
}

=head2 delSetFile

This deletes a specified set, for the filesystem backend.

Two arguements are required. The first one is the name of the config and the and
the second is the name of the set.

    if(!$zconf->delSetFile("foo/bar", "someset")){
        print "delSet failed\n";
    }
    
    #does the same, but using the zconf error reporting method
    $zconf->delSetFile("foo/bar", "someset");
    if(defined($zconf->{error})){
        print "delSet failed\n";
    }

=cut

sub delSetFile{
	my $self=$_[0];
	my $config=$_[1];
	my $set=$_[2];

	$self->errorBlank;

	#return if no set is given
	if (!defined($set)){
		warn("zconf delSetFile:24: \$set is not defined");
		$self->{error}=24;
		$self->{errorString}='$set not defined';
		return undef;
	}

	#return if no config is given
	if (!defined($config)){
		warn("zconf delSetFile:25: \$config is not defined");
		$self->{error}=25;
		$self->{errorString}='$config not defined';
		return undef;
	}

	#the path to the config
	my $configpath=$self->{args}{base}."/".$config;

	#returns with an error if it could not be set
	if (!-d $configpath) {
		warn('zconf delSetFile:14: "'.$config.'" is not a directory or does not exist');
		$self->{error}=14;
		$self->{errorString}='"'.$config.'" is not a directory or does not exist';
		return undef;
	}
	
	#the path to the set
	my $fullpath=$configpath."/".$set;

#not doing thie right now as I figure it is best just to delete the file and see if it goes or not
#	if (!-f $fullpath) {
#		warn('zconf delSetFile:14: "'.$filepath.'" is not a file or does not exist');
#		$self->{error}=14;
#		$self->{errorString}='"'.$filepath.'" is not a file or does not exist';
#	}

	if (!unlink($fullpath)) {
		warn('zconf delSetFile:29: "'.$fullpath.'" could not be unlinked');
		$self->{error}=29;
		$self->{errorString}='"'.$fullpath.'" could not be unlinked.';
		return undef;
	}

	return 1;
}

=head2 delSetLDAP

This deletes a specified set, for the LDAP backend.

Two arguements are required. The first one is the name of the config and the and
the second is the name of the set.

    if(!$zconf->delSetLDAP("foo/bar", "someset")){
        print "delSet failed\n";
    }
    
    #does the same, but using the zconf error reporting method
    $zconf->delSetLDAP("foo/bar", "someset");
    if(defined($zconf->{error})){
        print "delSet failed\n";
    }


=cut

sub delSetLDAP{
	my $self=$_[0];
	my $config=$_[1];
	my $set=$_[2];

	$self->errorBlank;

	#return if no config is given
	if (!defined($config)){
		warn("zconf delSet:25: \$config is not defined");
		$self->{error}=25;
		$self->{errorString}='$config not defined';
		return undef;
	}

	#creates the DN from the config
	my $dn=$self->config2dn($config).",".$self->{args}{"ldap/base"};

	#connects up to LDAP
	my $ldap=$self->LDAPconnect();
	if (defined($self->{error})) {
		warn('zconf delSetLDAP: LDAPconnect errored... returning...');
		return undef;
	}

	#gets the entry
	my $entry=$self->LDAPgetConfEntry($config, $ldap);
	#return upon error
	if (defined($self->{error})) {
		return undef;
	}

	if(!defined($entry->dn())){
		warn("zconf writeChooserLDAP:13: Expected DN, '".$dn."' not found.");
		$self->{error}=13;
		$self->{errorString}="Expected DN, '".$dn."' not found.";
		return undef;
	}else{
		if($entry->dn ne $dn){
			warn("zconf writeChooserLDAP:13: Expected DN, '".$dn."' not found.");
			$self->{error}=13;
			$self->{errorString}="Expected DN, '".$dn."' not found.";
			return undef;				
		};
	};
		
	#makes sure the zconfSet attribute is set for the config in question
	my @attributes=$entry->get_value('zconfSet');
	#if the 0th is not defined, it means this config does not have any sets or it is wrong
	if(defined($attributes[0])){
		#if $attributes dues contain enteries, make sure that one of them is the proper set
		my $attributesInt=0;
		my $setFound=0;#set to one if the loop finds the set
		while(defined($attributes[$attributesInt])){
			if($attributes[$attributesInt] eq $set){
				$setFound=1;
				$entry->delete(zconfSet=>[$attributes[$attributesInt]]);
			};
			$attributesInt++;
		};
	};

	#
	@attributes=$entry->get_value('zconfData');
	#if the 0th is not defined, it means there are no sets
	if(defined($attributes[0])){
		#if $attributes dues contain enteries, make sure that one of them is the proper set
		my $attributesInt=0;
		my $setFound=undef;#set to one if the loop finds the set
		while(defined($attributes[$attributesInt])){
			if($attributes[$attributesInt] =~ /^$set\n/){
				$setFound=1;
				$entry->delete(zconfData=>[$attributes[$attributesInt]]);
			};
			$attributesInt++;
		};
		#if the config is not found, add it
		if(!$setFound){
			warn('zconf delSetLDAP:25: The specified set, "'.$set.'" was not found for "'.$config.'".');
			$self->{error}=31;
			$self->{errorString}='The specified set, "'.$set.'" was not found for "'.$config.'".';
			return undef;
		};
	}else{
		warn('zconf delSetLDAP:25: No zconfData attributes exist for "'.$dn.'" and thus no sets exist.');
		$self->{error}=30;
		$self->{errorString}='No zconfData attributes exist for "'.$dn.'" and thus no sets exist.';
		return undef;
	}

	#write the entry to LDAP
	my $results=$entry->update($ldap);

	return 1;
}

=head2 errorBlank

This blanks the error storage and is only meant for internal usage.

It does the following.

	$zconf->{error}=undef;
	$zconf->{errorString}="";

=cut
	
#blanks the error flags
sub errorBlank{
	my $self=$_[0];
		
	$self->{error}=undef;
	$self->{errorString}="";
	
	return 1;
};

=head2 getAvailableSets

This gets the available sets for a config.

The only arguement is the name of the configuration in question.

	my @sets = $zconf->getAvailableSets("foo/bar");
	if(defined($zconf->{error})){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	};

=cut

#the overarching function for getting available sets
sub getAvailableSets{
	my ($self, $config) = @_;

	$self->errorBlank();

	#make sure the config name is legit
	my ($error, $errorString)=$self->configNameCheck($config);
	if(defined($error)){
		warn("zconf getAvailableSets:".$error.": ".$errorString);
		$self->{error}=$error;
		$self->{errorString}=$errorString;
		return undef;
	};

	#checks to make sure the config does exist
	if(!$self->configExists($config)){
		warn("zconf getAvailableSets:12: '".$config."' does not exist.");
		$self->{error}=12;
		$self->{errorString}="'".$config."' does not exist.";
		return undef;			
	};

	my @returned=undef;

	#get the sets
	if($self->{args}{backend} eq "file"){
		@returned=$self->getAvailableSetsFile($config);
	}else{
		if($self->{args}{backend} eq "ldap"){
			@returned=$self->getAvailableSetsLDAP($config);
		};
		#if it errors and read fall through is turned on, try the file backend
		if ($self->{error}&&$self->{args}{readfallthrough}) {
			$self->errorBlank;
			@returned=$self->getAvailableSetsFile($config);
		}
	};

	return @returned;
};

=head2 getAvailableSetsFile

This is exactly the same as getAvailableSets, but for the file back end.
For the most part it is not intended to be called directly.

	my @sets = $zconf->getAvailableSetsFile("foo/bar");
	if(defined($zconf->{error})){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	};

=cut

#this gets a set for a given file backed config
sub getAvailableSetsFile{
	my ($self, $config) = @_;

	#returns 0 if the config does not exist
	if(!-d $self->{args}{base}."/".$config){
		warn("zconf getAvailableSetsFille:14: '".$self->{args}{base}."/".$config."' does not exist.");
		$self->{error}=14;
		$self->{errorString}="'".$self->{args}{base}."/".$config."' does not exist.";
		return undef;
	};

	if(!opendir(CONFIGDIR, $self->{args}{base}."/".$config)){
		warn("zconf getAvailableSetsFille:15: '".$self->{args}{base}."/".$config."' open failed.");
		$self->{error}=15;
		$self->{errorString}="'".$self->{args}{base}."/".$config."' open failed.";
		return undef;
	};
	my @direntries=readdir(CONFIGDIR);
	closedir(CONFIGDIR);

	#remove hidden files and directory recursors from @direntries
	@direntries=grep(!/^\./, @direntries);
	@direntries=grep(!/^\.\.$/, @direntries);
	@direntries=grep(!/^\.$/, @direntries);

	my @sets=();

	#go though the list and return only files
	my $int=0;
	while(defined($direntries[$int])){
		if(-f $self->{args}{base}."/".$config."/".$direntries[$int]){
			push(@sets, $direntries[$int]);
		};
		$int++;
	};

	return @sets;
};

=head2 getAvailableSetsLDAP

This is exactly the same as getAvailableSets, but for the file back end.
For the most part it is not intended to be called directly.

	my @sets = $zconf->getAvailableSetsLDAP("foo/bar");
	if(defined($zconf->{error})){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	};

=cut

sub getAvailableSetsLDAP{
	my ($self, $config) = @_;
		
	#converts the config name to a DN
	my $dn=$self->config2dn($config).",".$self->{args}{"ldap/base"};

	#gets the message
	my $ldapmesg=$self->LDAPgetConfMessage($config);
	#return upon error
	if (defined($self->{error})) {
		return undef;
	}

	my %hashedmesg=LDAPhash($ldapmesg);
	if(!defined($hashedmesg{$dn})){
		warn("zconf getAvailableSetsLDAP:13: Expected DN, '".$dn."' not found.");
		$self->{error}=13;
		$self->{errorString}="Expected DN, '".$dn."' not found.";
		return undef;
	};
		
	my $setint=0;
	my @sets=();
	while(defined($hashedmesg{$dn}{ldap}{zconfSet}[$setint])){
		$sets[$setint]=$hashedmesg{$dn}{ldap}{zconfSet}[$setint];
		$setint++;
	};
		
	return @sets;
};

=head2 getDefault

This gets the default set currently being used if one is not choosen.

	my $defaultSet = $zml->getDefault();

=cut
	
#gets what the default set is
sub getDefault{
	my ($self)= @_;

	return $self->{args}{default};
};

=head2 getKeys

This gets gets the keys for a loaded config.

	my @keys = $zconf->getKeys("foo/bar")
	if(defined($zconf->{error})){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	};

=cut

#get a list of keys for a config
sub getKeys {
	my ($self, $config) = @_;

	if(!defined($self->{conf}{$config})){
		warn("zconf getKeys:26: Config '".$config."' is not loaded.");
		$self->{error}=26;
		$self->{errorString}="Config '".$config."' is not loaded.";
		return undef;
	};

	my @keys=keys(%{$self->{conf}{$config}});

	return @keys;
};

=head2 getLoadedConfigs

This gets gets the keys for a loaded config.

	my @configs = $zconf->getLoadedConfigs("foo/bar")
	if($zconf->{error}){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	};

=cut

#get a list loaded configs
sub getLoadedConfigs {
	my ($self, $config) = @_;

	my @keys=keys(%{$self->{conf}});

	return @keys;
};

=head2 getSet

This gets the set for a loaded config.

	my $set = $zconf->getSet("foo/bar")
	if(defined($zconf->{error})){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	};

=cut

#get the set a config is currently using
sub getSet{
	my ($self, $config)= @_;
	
	if(!defined($self->{set}{$config})){
		warn("zconf getSet:26: Set '".$config."' is not loaded.");
		$self->{error}=26;
		$self->{errorString}="Set '".$config."' is not loaded.";
		return undef;
	};
	
	return $self->{set}{$config};
};

=head2 getSubConfigs

This gets any sub configs for a config. "" can be used to get a list of configs
under the root.

One arguement is accepted and that is the config to look under.

    #lets assume 'foo/bar' exists, this would return
    my @subConfigs=$zconf->getSubConfigs("foo");
    if(defined($zconf->{error})){
        print "There was some error.\n";
    }

=cut

#gets the configs under a config
sub getSubConfigs{
	my ($self, $config)= @_;

	#blank any previous errors
	$self->errorBlank;

	#make sure the config name is legit
	my ($error, $errorString)=$self->configNameCheck($config);
	if(defined($error)){
		warn("zconf getSubConfigs:".$error.": ".$errorString);
		$self->{error}=$error;
		$self->{errorString}=$errorString;
		return undef;
	}

	my @returned;

	#get the sub configs
	if($self->{args}{backend} eq "file"){
		@returned=$self->getSubConfigsFile($config);
	}else{
		if($self->{args}{backend} eq "ldap"){
			@returned=$self->getSubConfigsLDAP($config);
		}
		#if it errors and read fall through is turned on, try the file backend
		if ($self->{error}&&$self->{args}{readfallthrough}) {
			$self->errorBlank;
			@returned=$self->getSubConfigsFile($config);
		}
	}

	return @returned;
}

=head2 getSubConfigsFile

This gets any sub configs for a config. "" can be used to get a list of configs
under the root.

One arguement is accepted and that is the config to look under.

    #lets assume 'foo/bar' exists, this would return
    my @subConfigs=$zconf->getSubConfigs("foo");
    if(defined($zconf->{error})){
        print "There was some error.\n";
    }

=cut

#gets the configs under a config
sub getSubConfigsFile{
	my ($self, $config)= @_;

	#returns 0 if the config does not exist
	if(!-d $self->{args}{base}."/".$config){
		warn("zconf getSubConfigsFile:14: '".$self->{args}{base}.
			 "/".$config."' does not exist.");
		$self->{error}=14;
		$self->{errorString}="'".$self->{args}{base}."/".$config."' does not exist.";
		return undef;
	};

	if(!opendir(CONFIGDIR, $self->{args}{base}."/".$config)){
		warn("zconf getSubConfigsFile:15: '".$self->{args}{base}."/".$config.
			 "' open failed.");
		$self->{error}=15;
		$self->{errorString}="'".$self->{args}{base}."/".$config."' open failed.";
		return undef;
	};
	my @direntries=readdir(CONFIGDIR);
	closedir(CONFIGDIR);

	#remove, ""^."" , ""."" , and "".."" from @direntries
	@direntries=grep(!/^\./, @direntries);
	@direntries=grep(!/^\.\.$/, @direntries);
	@direntries=grep(!/^\.$/, @direntries);

	my @sets=();

	#go though the list and return only files
	my $int=0;
	while(defined($direntries[$int])){
		if(-d $self->{args}{base}."/".$config."/".$direntries[$int]){
			push(@sets, $direntries[$int]);
		};
		$int++;
	};

	return @sets;
}

=head2 getSubConfigsLDAP

This gets any sub configs for a config. "" can be used to get a list of configs
under the root.

One arguement is accepted and that is the config to look under.

    #lets assume 'foo/bar' exists, this would return
    my @subConfigs=$zconf->getSubConfigs("foo");
    if(defined($zconf->{error})){
        print "There was some error.\n";
    }

=cut

#gets the configs under a config
sub getSubConfigsLDAP{
	my ($self, $config)= @_;

	my $dn;
	#converts the config name to a DN
	if ($config eq "") {
		#this is done as using config2dn results in an error
		$dn=$self->{args}{"ldap/base"};
	}else{
		$dn=$self->config2dn($config).",".$self->{args}{"ldap/base"};
	}

	#gets the message
	my $ldapmesg=$self->LDAPgetConfMessageOne($config);
	#return upon error
	if (defined($self->{error})) {
		return undef;
	}

	my %hashedmesg=LDAPhash($ldapmesg);

	#
	my @keys=keys(%hashedmesg);

	#holds the returned sets
	my @sets;

	my $keysInt=0;
	while ($keys[$keysInt]){
		#only process ones that start with 'cn='
		if ($keys[$keysInt] =~ /^cn=/) {
			#remove the begining config DN chunk
			$keys[$keysInt]=~s/,$dn$//;
			#removes the cn= at the begining
			$keys[$keysInt]=~s/^cn=//;
			#push the processed key onto @sets
			push(@sets, $keys[$keysInt]);
	    }
		
		$keysInt++;
	}

	return @sets;
}

=head2 LDAPconnect

This generates a Net::LDAP object based on the LDAP backend.

    my $ldap=$zconf->LDAPconnect();
    if(defined($zconf->{error})){
        print "error!";
    }

=cut

sub LDAPconnect{
	my $self=$_[0];

	$self->errorBlank;

	#connects up to LDAP
	my $ldap;
	eval {
   		$ldap =Net::LDAP::Express->new(host => $self->{args}{"ldap/host"},
				bindDN => $self->{args}{"ldap/bind"},
				bindpw => $self->{args}{"ldap/password"},
				base   => $self->{args}{"ldap/homeDN"},
				searchattrs => [qw(dn)]);
	};
	if($@){
		warn("zconf LDAPconnect:1: LDAP connection failed with '".$@."'.");
		$self->{error}=1;
		$self->{errorString}="LDAP connection failed with '".$@."'";
		return undef;
	};

	return $ldap;
}

=head2 LDAPgetConfMessage

Gets a Net::LDAP::Message object that was created doing a search for the config with
the scope set to base.

    #gets it for 'foo/bar'
    my $mesg=$zconf->LDAPgetConfMessage('foo/bar');
    #gets it using $ldap for the connection
    my $mesg=$zconf->LDAPgetConfMessage('foo/bar', $ldap);
    if(defined($zconf->{error})){
        print "error!";
    }

=cut

sub LDAPgetConfMessage{
	my $self=$_[0];
	my $config=$_[1];
	my $ldap=$_[2];

	$self->errorBlank;

	#only connect to LDAP if needed
	if (!defined($ldap)) {
		#connects up to LDAP
		$ldap=$self->LDAPconnect;
		#return upon error
		if (defined($self->{error})) {
			return undef;
		}
	}

	#creates the DN from the config
	my $dn=$self->config2dn($config).",".$self->{args}{"ldap/base"};

	#gets the message
	my $ldapmesg=$ldap->search(scope=>"base", base=>$dn,filter => "(objectClass=*)");

	return $ldapmesg;
}

=head2 LDAPgetConfMessageOne

Gets a Net::LDAP::Message object that was created doing a search for the config with
the scope set to one.

    #gets it for 'foo/bar'
    my $mesg=$zconf->LDAPgetConfMessageOne('foo/bar');
    #gets it using $ldap for the connection
    my $mesg=$zconf->LDAPgetConfMessageOne('foo/bar', $ldap);
    if(defined($zconf->{error})){
        print "error!";
    }

=cut

sub LDAPgetConfMessageOne{
	my $self=$_[0];
	my $config=$_[1];
	my $ldap=$_[2];

	$self->errorBlank;

	#only connect to LDAP if needed
	if (!defined($ldap)) {
		#connects up to LDAP
		$ldap=$self->LDAPconnect;
		#return upon error
		if (defined($self->{error})) {
			warn('zconf LDAPgetConfMessageOne: LDAPconnect errored... returning...');
			return undef;
		}
	}

	#creates the DN from the config
	my $dn=$self->config2dn($config).",".$self->{args}{"ldap/base"};

	$dn =~ s/^,//;

	#gets the message
	my $ldapmesg=$ldap->search(scope=>"one", base=>$dn,filter => "(objectClass=*)");

	return $ldapmesg;
}

=head2 LDAPgetConfEntry

Gets a Net::LDAP::Message object that was created doing a search for the config with
the scope set to base.

It returns undef if it is not found.

    #gets it for 'foo/bar'
    my $entry=$zconf->LDAPgetConfEntry('foo/bar');
    #gets it using $ldap for the connection
    my $entry=$zconf->LDAPgetConfEntry('foo/bar', $ldap);
    if(defined($zconf->{error})){
        print "error!";
    }

=cut

sub LDAPgetConfEntry{
	my $self=$_[0];
	my $config=$_[1];
	my $ldap=$_[2];

	$self->errorBlank;

	#only connect to LDAP if needed
	if (!defined($ldap)) {
		#connects up to LDAP
		$ldap=$self->LDAPconnect;
		#return upon error
		if (defined($self->{error})) {
			return undef;
		}
	}

	#creates the DN from the config
	my $dn=$self->config2dn($config).",".$self->{args}{"ldap/base"};

	#gets the message
	my $ldapmesg=$ldap->search(scope=>"base", base=>$dn,filter => "(objectClass=*)");
	my $entry=$ldapmesg->entry;

	return $entry;
}

=head2 read

This reads a config. The only accepted option is the config name.

It takes one arguement, which is a hash. 'config' is the only required key
in the hash and it holds the name of the config to be loaded. If set is
defined in the hash, that specified set be used instead of the default or
automatically choosen one.

	if(!$zconf->read({config=>"foo/bar"})){
		print "'foo/bar' does not exist\n";
	};

	#does the same thing above, but using the error interface
	my $returned = $zconf->read({config=>"foo/bar"})
	if(defined($zconf->{error})){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	};

=cut

#the overarching read
sub read{
	my $self=$_[0];
	my %args=%{$_[1]};

	$self->errorBlank;

	#return false if the config is not set
	if (!defined($args{config})){
		warn("zconf read:12: \$config is not defined");
		$self->{error}=17;
		$self->{errorString}='$config not defined';
		return undef;			
	};

	#make sure the config name is legit
	my ($error, $errorString)=$self->configNameCheck($args{config});
	if(defined($error)){
		warn("zconf read:12:".$error.": ".$errorString);
		$self->{error}=$error;
		$self->{errorString}=$errorString;
		return undef;
	};

	#checks to make sure the config does exist
	if(!$self->configExists($args{config})){
		warn("zconf read:12: '".$args{config}."' does not exist");
		$self->{error}=12;
		$self->{errorString}="'".$args{config}."' does not exist.";
		return undef;			
	};

	#gets the set to use if not set
	if(!defined($args{set})){
		$args{set}=$self->chooseSet($args{config});
		if (defined($self->{error})) {
			warn('zconf read:32: Unable to choose a set');
			$self->{error}='32';
			$self->{errorString}='Unable to choose a set.';
			return undef;
		}
	};

	my $returned=undef;
		
	#loads the config
	if($self->{args}{backend} eq "file"){
		$returned=$self->readFile(\%args);
	}else{
		if($self->{args}{backend} eq "ldap"){
			$returned=$self->readLDAP(\%args);
		};
		#if it errors and read fall through is turned on, try the file backend
		if ($self->{error}&&$self->{args}{readfallthrough}) {
			$self->errorBlank;
			$returned=$self->readFile(\%args);
			#we return here because if we don't we will pointlessly sync it
			return $returned;
		}
	};
		
	if(!$returned){
		return undef;
	};
		
	#attempt to sync the config locally if not using the file backend
	if($self->{args}{backend} ne "file"){
		my $syncReturn=$self->writeSetFromLoadedConfigFile(\%args);
		if (!$syncReturn){
			print "zconf read error: Could not sync config to the loaded config.";
		};
	};

	return 1;
};

=head2 readFile

readFile functions just like read, but is mainly intended for internal use
only. This reads the config from the file backend.

	if(!$zconf->readFile({config=>"foo/bar"})){
		print "'foo/bar' does not exist\n";
	};

	#does the same thing above, but using the error interface
	my $returned = $zconf->readFile({config=>"foo/bar"})
	if(defined($zconf->{error})){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	};

=cut

#read a config from a file
sub readFile{
	my $self=$_[0];
	my %args=%{$_[1]};

	$self->errorBlank;

	#return false if the config is not set
	if (!defined($args{config})){
		warn("zconf readFile:12: \$config is not defined");
		$self->{error}=17;
		$self->{errorString}='$config not defined';
		return undef;			
	};

	#return false if the config is not set
	if (!defined($args{set})){
		warn("zconf readFile:24: \$arg{set} is not defined");
		$self->{error}=24;
		$self->{errorString}='$arg{set} not defined';
		return undef;			
	};

	my $fullpath=$self->{args}{base}."/".$args{config}."/".$args{set};

	#return false if the full path does not exist
	if (!-f $fullpath){
		return 0;
	};

	#retun from a this if a comma is found in it
	if( $args{config} =~ /,/){
		return 0;
	};

	if(!open("thefile", $fullpath)){
		return 0;
	};
	my @rawdata=<thefile>;
	close("thefile");

	#at this point we add
	$self->{conf}{$args{config}}={};

	my $rawdataInt=0;
	my $prevVar=undef;
	while(defined($rawdata[$rawdataInt])){
		if($rawdata[$rawdataInt] =~ /^ /){
			#this if statement prevents it from being ran on the first line if it is not properly formated
			if(defined($prevVar)){
				chomp($rawdata[$rawdataInt]);
				$rawdata[$rawdataInt]=~s/^ //;#remove the trailing space
				#add in the line return and 
				$self->{conf}{$args{config}}{$prevVar}=
					$self->{conf}{$args{config}}{$prevVar}."\n".$rawdata[$rawdataInt];
			};
		}else{
			#split it into two
			my @linesplit=split(/=/, $rawdata[$rawdataInt], 2);
			chomp($linesplit[1]);
			$self->{conf}{$args{config}}{$linesplit[0]}=$linesplit[1];
			$prevVar=$linesplit[0];#this is used if the next line is a continuation from the previous
		};

		$rawdataInt++;
	};

	#sets the set that was read		
	$self->{set}{$args{config}}=$args{set};

	return 1;
};

=head2 readLDAP

readFile functions just like read, but is mainly intended for internal use
only. This reads the config from the LDAP backend.

	if(!$zconf->readLDAP({config=>"foo/bar"})){
		print "'foo/bar' does not exist\n";
	};

	#does the same thing above, but using the error interface
	my $returned = $zconf->readLDAP({config=>"foo/bar"})
	if(defined($zconf->{error})){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	};

=cut

#read a config from a file
sub readLDAP{
	my $self=$_[0];
	my %args=%{$_[1]};

	$self->errorBlank;

	#return false if the config is not set
	if (!defined($args{config})){
		warn("zconf readLDAP:12: \$config is not defined");
		$self->{error}=17;
		$self->{errorString}='$config not defined';
		return undef;			
	};

	#return false if the config is not set
	if (!defined($args{set})){
		warn("zconf readFile:24: \$arg{set} is not defined");
		$self->{error}=24;
		$self->{errorString}='$arg{set} not defined';
		return undef;			
	};

	#creates the DN from the config
	my $dn=$self->config2dn($args{config}).",".$self->{args}{"ldap/base"};

	#gets the LDAP entry
	my $entry=$self->LDAPgetConfEntry($args{config});
	#return upon error
	if (defined($self->{error})) {
		return undef;
	}

	if(!defined($entry->dn())){
		warn("zconf readLDAP:13: Expected DN, '".$dn."' not found.");
		$self->{error}=13;
		$self->{errorString}="Expected DN, '".$dn."' not found.";
		return undef;
	}else{
		if($entry->dn ne $dn){
			warn("zconf readLDAP:13: Expected DN, '".$dn."' not found.");
			$self->{error}=13;
			$self->{errorString}="Expected DN, '".$dn."' not found.";
			return undef;			
		};
	};

	my @attributes=$entry->get_value('zconfData');
	my $data=undef;#unset from undef if matched
	if(defined($attributes[0])){
		#if @attributes has entries, go through them looking for a match
		my $attributesInt=0;
		my $setFound=undef;#set to one if the loop finds the set
		while(defined($attributes[$attributesInt])){
			if($attributes[$attributesInt] =~ /^$args{set}\n/){
				#if a match is found, save it to data for continued processing
				$data=$attributes[$attributesInt];
			};
			$attributesInt++;
		};
	}else{
		#If we end up here, it means it is a bad LDAP enty
		warn("zconf readLDAP:13: No zconfData entry found in '".$dn."'.");
		$self->{error}=13;
		$self->{errorString}="No zconfData entry found in '".$dn."'.";
		return undef;	
	};

	#error out if $data is undefined
	if(!defined($data)){
		warn("zconf readLDAP:13: No matching sets found in '".$args{config}."'.");
		$self->{error}=13;
		$self->{errorString}="No matching sets found in '".$args{config}."'.";
		return undef;	
	};
	
		
	#removes the firstline from the data
	$data=~s/^$args{set}\n//;
	
	#parse the ZML stuff
	my $zml=ZML->new();
	$zml->parse($data);
	if($zml->{error}){
		warn("ZConf readLDAP:28: ZML->parse error, '".$zml->{error}."', '".$zml->{errorString}."'.");
		$self->{error}=28;
		$self->{errorString}="ZConf readLDAP:28: ZML->parse error, '".$zml->{error}."', '".$zml->{errorString}."'.";
		return undef;
	};
	$self->{conf}{$args{config}}={%{$zml->{var}}};

	#sets the loaded config
	$self->{set}{$args{config}}=$args{set};

	return 1;
};

=head2 readChooser

This reads the chooser for a config. If no chooser is defined "" is returned.

The name of the config is the only required arguement.

	my $chooser = $zconf->readChooser("foo/bar")
	if(defined($zconf->{error})){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	};

=cut

#the overarching readChooser
#this gets the chooser for a the config
sub readChooser{
	my ($self, $config)= @_;

	$self->errorBlank;

	#return false if the config is not set
	if (!defined($config)){
		warn("zconf readChooser:12: \$config is not defined");
		$self->{error}=17;
		$self->{errorString}='$config not defined';
		return undef;			
	};

	#make sure the config name is legit
	my ($error, $errorString)=$self->configNameCheck($config);
	if(defined($error)){
		warn("zconf readChooser:12:".$error.": ".$errorString);
		$self->{error}=$error;
		$self->{errorString}=$errorString;
		return undef;
	};

	#checks to make sure the config does exist
	if(!$self->configExists($config)){
		warn("zconf readChooser:12: '".$config."' does not exist.");
		$self->{error}=12;
		$self->{errorString}="'".$config."' does not exist.";
		return undef;			
	};
		
	my $returned=undef;

	#reads the chooser
	if($self->{args}{backend} eq "file"){
		$returned=$self->readChooserFile($config);
	}else{
		if($self->{args}{backend} eq "ldap"){
			$returned=$self->readChooserLDAP($config);
		};
		#if it errors and read fall through is turned on, try the file backend
		if ($self->{error}&&$self->{args}{readfallthrough}) {
			$self->errorBlank;
			$returned=$self->readChooserFile($config);
			#we return here because if we don't we will pointlessly sync it
			return $returned;
		}
	};

	if($self->{error}){
		return undef;
	};

	#attempt to sync the chooser locally if not using the file backend
	if($self->{args}{backend} ne "file"){
		my $syncReturn=$self->writeChooserFile($config, $returned);
		if (!$syncReturn){
			warn("zconf readChooser: sync failed");				
		};
	};

	return $returned;
};

=head2 readChooserFile




This functions just like readChooser, but functions on the file backend
and only really intended for internal use.

	my $chooser = $zconf->readChooserFile("foo/bar");
	if(defined($zconf->{error})){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	};

=cut

#this gets the chooser for a the config... for the file backend
sub readChooserFile{
	my ($self, $config)= @_;

	#return false if the config is not set
	if (!defined($config)){
		warn("zconf readChooserFromFile:12: \$config is not defined");
		$self->{error}=17;
		$self->{errorString}='$config not defined';
		return undef;			
	};

	#make sure the config name is legit
	my ($error, $errorString)=$self->configNameCheck($config);
	if(defined($error)){
		warn("zconf readChooserFromFile:12:".$error.": ".$errorString);
		$self->{error}=$error;
		$self->{errorString}=$errorString;
		return undef;
	};
		
	#checks to make sure the config does exist
	if(!$self->configExists($config)){
		warn("zconf readChooserFromFile:12: '".$config."' does not exist.");
		$self->{error}=12;
		$self->{errorString}="'".$config."' does not exist.";
		return undef;			
	};

	#the path to the file
	my $chooser=$self->{args}{base}."/".$config."/.chooser";

	#if the chooser does not exist, turn true, but blank 
	if(!-f $chooser){
		return "";
	};

	#open the file and get the string error on not being able to open it 
	if(!open("READCHOOSER", $chooser)){
		warn("zconf readChooserFromFile:17: '".$self->{args}{base}."/".$config."/.chooser' read failed.");
		$self->{error}=15;
		$self->{errorString}="'".$self->{args}{base}."/".$config."/.chooser' read failed.";
		return undef;
	};
	my $chooserstring=<READCHOOSER>;
	close("READCHOOSER");		

	return ($chooserstring);
};

=head2 readChooserLDAP

This functions just like readChooser, but functions on the LDAP backend
and only really intended for internal use.

	my $chooser = $zconf->readChooserLDAP("foo/bar");
	if(defined($zconf->{error})){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	};

=cut

#this gets the chooser for a the config... for the file backend
sub readChooserLDAP{
	my ($self, $config)= @_;

	#return false if the config is not set
	if (!defined($config)){
		warn("zconf readChooserFromFile:12: \$config is not defined");
		$self->{error}=17;
		$self->{errorString}='$config not defined';
		return undef;			
	};

	#make sure the config name is legit
	my ($error, $errorString)=$self->configNameCheck($config);
	if(defined($error)){
		warn("zconf readChooserFromFile:12:".$error.": ".$errorString);
		$self->{error}=$error;
		$self->{errorString}=$errorString;
		return undef;
	};

	#checks to make sure the config does exist
	if(!$self->configExists($config)){
		warn("zconf readChooserFromFile:12: '".$config."' does not exist.");
		$self->{error}=12;
		$self->{errorString}="'".$config."' does not exist.";
		return undef;			
	};

	#creates the DN from the config
	my $dn=$self->config2dn($config).",".$self->{args}{"ldap/base"};

	#gets the LDAP mesg
	my $ldapmesg=$self->LDAPgetConfMessage($config);
	#return upon error
	if (defined($self->{error})) {
		return undef;
	}

	my %hashedmesg=LDAPhash($ldapmesg);
	if(!defined($hashedmesg{$dn})){
		warn("zconf readChooserFromLDAP:13: Expected DN, '".$dn."' not found.");
		$self->{error}=13;
		$self->{errorString}="Expected DN, '".$dn."' not found.";
		return undef;
	};

	if(defined($hashedmesg{$dn}{ldap}{zconfChooser}[0])){
		return($hashedmesg{$dn}{ldap}{zconfChooser}[0]);
	}else{
		return("");
	};
};

=head2 regexVarDel

This searches through the variables in a loaded config for any that match
the supplied regex and removes them.

Two arguements are required. The first is the config to search. The second
is the regular expression to use.

	#removes any variable starting with the monkey
	my @deleted = $zconf->regexVarDel("foo/bar", "^monkey");
	if(defined($zconf->{error})){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	};

=cut

#removes variables based on a regex
sub regexVarDel{
	my ($self, $config, $regex) = @_;

	if(!defined($self->{conf}{$config})){
		warn("zconf regexVarDel:25: Config '".$config."' is not loaded.");
		$self->{error}=25;
		$self->{errorString}="Config '".$config."' is not loaded.";
		return undef;
	};

	my @keys=keys(%{$self->{conf}{$config}});

	my @returnKeys=();

	my $int=0;
	while(defined($keys[$int])){
		if($keys[$int] =~ /$regex/){
			delete($self->{conf}{$config}{$keys[$int]});
			push(@returnKeys, $keys[$int]);
		};

		$int++;
	};

	return @returnKeys;				
};

=head2 regexVarGet

This searches through the variables in a loaded config for any that match
the supplied regex and returns them in a hash.

Two arguements are required. The first is the config to search. The second
is the regular expression to use.

	#returns any variable begining with monkey
	my %vars = $zconf->regexVarGet("foo/bar", "^monkey");
	if(defined($zconf->{error})){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	};

=cut

#returns a hash of regex matched vars
#return undef on error	
sub regexVarGet{
	my ($self, $config, $regex) = @_;

	if(!defined($self->{conf}{$config})){
		warn("zconf regexVarGet:26: Config '".$config."' is not loaded.");
		$self->{error}=25;
		$self->{errorString}="Config '".$config."' is not loaded.";
		return undef;
	};

	my @keys=keys(%{$self->{conf}{$config}});

	my %returnKeys=();

	my $int=0;
	while(defined($keys[$int])){
		if($keys[$int] =~ /$regex/){
			$returnKeys{$keys[$int]}=$self->{conf}{$config}{$keys[$int]};
		};
			
		$int++;
	};

	return %returnKeys;
};

=head2 regexVarSearch

This searches through the variables in a loaded config for any that match
the supplied regex and returns a array of matches.

Two arguements are required. The first is the config to search. The second
is the regular expression to use.

	#removes any variable starting with the monkey
	my @matched = $zconf->regexVarSearch("foo/bar", "^monkey")
	if($zconf->{error})){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	};

=cut

#search variables based on a regex	
sub regexVarSearch{
	my ($self, $config, $regex) = @_;

	if(!defined($self->{conf}{$config})){
		warn("zconf regexVarSearch:25: Config '".$config."' is not loaded.");
		$self->{error}=25;
		$self->{errorString}="Config '".$config."' is not loaded.";
		return undef;
	};

	my @keys=keys(%{$self->{conf}{$config}});

	my @returnKeys=();

	my $int=0;
	while(defined($keys[$int])){
		if($keys[$int] =~ /$regex/){
			push(@returnKeys, $keys[$int]);
		};
			
		$int++;
	};

	return @returnKeys;
};

=head2 setDefault

This sets the default set to use if one is not specified or choosen.

	if(!$zconf->setDefault("something")){
		print "'something' is not a legit set name\n";
	};

	#sets what the default set is
	my $returned = $zconf->setDefault("something")
	if($zconf->{error}){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	};

=cut
	
#sets the default set
sub setDefault{
	my ($self, $set)= @_;

	#blank any errors
	$self->errorBlank;

	if($self->setNameLegit($set)){
		$self->{args}{default}=$set;
	}else{
		warn("zconf setDefault:27: '".$set."' is not a legit set name.");
		$self->{error}=27;
		$self->{errorString}="'".$set."' is not a legit set name.";
		return undef
	};

	return 1;
};

=head2 setExists

This checks if the specified set exists.

Two arguements are required. The first arguement is the name of the config.
The second arguement is the name of the set. If no set is specified, the default
set is used. This is done by calling 'defaultSetExists'.

    if($zconf->setExists("foo/bar", "fubar")){
        print "It exists.\n";
    }

    #the same, but using error checking as well
    my $return=$zconf->setExists("foo/bar", "fubar");
    if(defined($zconf->{error})){
        print "Error!\n";
    }else{
        if($return){
            print "It exists.\n";
        }
    }

=cut

sub setExists{
	my ($self, $config, $set)= @_;

	#blank any errors
	$self->errorBlank;

	#this will get what set to use if it is not specified
	if (!defined($set)) {
		return $self->defaultSetExists($config);
		if ($self->{error}) {
			warn('ZConf setExists: No set specified and defaultSetExists errored');
			return undef;
		}
	}

	#We don't do any config name checking here or even if it exists as getAvailableSets
	#will do that.

	my @sets = $self->getAvailableSets($config);
	if (defined($self->{error})) {
		return undef;
	}


	my $setsInt=0;#used for intering through $sets
	#go through @sets and check for matches
	while (defined($sets[$setsInt])) {
		#return true if the current one matches
		if ($sets[$setsInt] eq $set) {
			return 1;
		}

		$setsInt++;
	}

	#if we get here, it means it was not found in the loop
	return undef;
}

=head2 setNameLegit

This checks if a setname is legit.

There is one required arguement, which is the set name.

The returned value is a perl boolean value.

	my $set="something";
	if(!$zconf->setNameLegit($set)){
		print "'".$set."' is not a legit set name.\n";
	};

=cut

#checks the setnames to make sure they are legit.
sub setNameLegit{
	my ($self, $set)= @_;

	if (!defined($set)){
		return undef;
	};

	#return false if it / is found
	if ($set =~ /\//){
		return undef;
	};
		
	#return undef if it begins with .
	if ($set =~ /^\./){
		return undef;
	};

	#return undef if it begins with " "
	if ($set =~ /^ /){
		return undef;
	};

	#return undef if it ends with " "
	if ($set =~ / $/){
		return undef;
	};

	#return undef if it contains ".."
	if ($set =~ /\.\./){
		return undef;
	};

	return 1;
};

=head2 setVar

This sets a variable in a loaded config.

Three arguements are required. The first is the name of the config.
The second is the name of the variable. The third is the value.

	if(!$zconf->setVar("foo/bar" , "something", "eat more weazel\n\nor something")){
		print "A error occured when trying to set a variable.\n";
	};

	#sets what the default set is
	my $returned = $zconf->setVar("foo/bar" , "something", "eat more weazel\n\nor something"
	if($zconf->{error}){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	};


=cut

#sets a variable
sub setVar{
	my ($self, $config, $var, $value) = @_;

	#blank the any previous errors
	$self->errorBlank;

	#make sure the config name is legit
	my ($error, $errorString)=$self->configNameCheck($config);
	if(defined($error)){
		warn("zconf setVar:12:".$error.": ".$errorString);
		$self->{error}=$error;
		$self->{errorString}=$errorString;
		return undef;
	};

	#make sure the config name is legit
	($error, $errorString)=$self->varNameCheck($var);
	if(defined($error)){
		warn("zconf setVar:12:".$error.": ".$errorString);
		$self->{error}=$error;
		$self->{errorString}=$errorString;
		return undef;
	};

	if(!defined($self->{conf}{$config})){
		warn("zconf setVar:25: Config '".$config."' is not loaded.");
		$self->{error}=25;
		$self->{errorString}="Config '".$config."' is not loaded.";
		return undef;
	};

	if(!defined($var)){
		warn("zconf setVar:18: \$var is not defined.");
		$self->{error}=18;
		$self->{errorString}="\$var is not defined.";
		return undef;
	};

	$self->{conf}{$config}{$var}=$value;

	return 1;
};

=head2 unloadConfig

Unloads a specified configuration. The only required value is the
set name. The return value is a Perl boolean value.

    if(!$zconf->unloadConfig($config)){
        print "error: ".$zconf->{error}."\n";
    }

=cut

sub unloadConfig{
	my $self=$_[0];
	my $config=$_[1];

	$self->errorBlank();

	if (!defined($self->{conf}{$config})){
		warn('ZConf:26: The specified config, ".$config.", is not loaded');
		$self->{error}=26;
		$self->{errorString}='The specified config, ".$config.", is not loaded';
		#even if it is not defined, check to see if this is defined and remove it
		if (defined($self->{set}{$config})){
			undef($self->{set}{$config});
		}
		return undef;
	}else {
		undef($self->{conf}{$config});
	}

	#removes the loaded set information
	if (defined($self->{set}{$config})){
		undef($self->{set}{$config});
	}

	return 1;
}

=head2 varNameCheck

	my ($error, $errorString) = $zconf->varNameCheck($config);
	if(defined($error)){
		$self->{error}=$error;
		$self->{errorString}=$errorString;
		return undef;
	};

=cut

sub varNameCheck{
        my ($self, $name) = @_;

		#makes sure it is defined
		if (!defined($name)) {
			return('10', 'variable name is not defined');
		};

        #checks for ,
        if($name =~ /,/){
                return("0", "variavble name,'".$name."', contains ','");
        };

        #checks for /.
        if($name =~ /\/\./){
                return("1", "variavble name,'".$name."', contains '/.'");
        };

        #checks for //
        if($name =~ /\/\//){
                return("2", "variavble name,'".$name."', contains '//'");
        };

        #checks for ../
        if($name =~ /\.\.\//){
                return("3", "variavble name,'".$name."', contains '../'");
        };

        #checks for /..
        if($name =~ /\/\.\./){
                return("4", "variavble name,'".$name."', contains '/..'");
        };

        #checks for ^./
        if($name =~ /^\.\//){
                return("5", "variavble name,'".$name."', matched /^\.\//");
        };

        #checks for /$
        if($name =~ /\/$/){
                return("6", "variavble name,'".$name."', matched /\/$/");
        };

        #checks for ^/
        if($name =~ /^\//){
                return("7", "variavble name,'".$name."', matched /^\//");
        };

        #checks for \\n
        if($name =~ /\n/){
                return("8", "variavble name,'".$name."', matched /\\n/");
        };

        #checks for =
        if($name =~ /=/){
                return("9", "variavble name,'".$name."', matched /=/");
        };

		return(undef, "");	
};

=head2 writeChooser

This writes a string into the chooser for a config.

There are two required arguements. The first is the
config name. The second is chooser string.

No error checking is done currently on the chooser string.

	#writes the contents of $chooserString to the chooser for "foo/bar"
	if(!$zconf->writeChooser("foo/bar", $chooserString)){
		print "it failed\n";
	};

	#does the same thing above, but using the error interface
	my $returned = $zconf->writeChooser("foo/bar", $chooserString)
	if(defined($zconf->{error})){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	};

=cut

#the overarching read
sub writeChooser{
	my ($self, $config, $chooserstring)= @_;

	$self->errorBlank;

	#return false if the config is not set
	if (!defined($config)){
		warn("zconf writeChooser:12: \$config is not defined");
		$self->{error}=17;
		$self->{errorString}='$config not defined';
		return undef;			
	};

	#return false if the config is not set
	if (!defined($chooserstring)){
		warn("zconf writeChooser:12: \$chooserstring is not defined");
		$self->{error}=17;
		$self->{errorString}='\$chooserstring not defined';
		return undef;			
	};

	#make sure the config name is legit
	my ($error, $errorString)=$self->configNameCheck($config);
	if(defined($error)){
		warn("zconf writeChooser:12:".$error.": ".$errorString);
		$self->{error}=$error;
		$self->{errorString}=$errorString;
		return undef;
	};
		
	#checks to make sure the config does exist
	if(!$self->configExists($config)){
		warn("zconf writeChooser:12: '".$config."' does not exist.");
		$self->{error}=12;
		$self->{errorString}="'".$config."' does not exist.";
		return undef;			
	};

	if(defined($self->{error})){
		return undef;
	};

	my $returned=undef;

	#reads the chooser
	if($self->{args}{backend} eq "file"){
		$returned=$self->writeChooserFile($config, $chooserstring);
	}else{
		if($self->{args}{backend} eq "ldap"){
			$returned=$self->writeChooserLDAP($config, $chooserstring);
		};


	};

	if(!$returned){
		return undef;
	};
		
	#attempt to sync the chooser locally if not using the file backend
	if($self->{args}{backend} ne "file"){
		my $syncReturn=$self->writeChooserFile($config, $chooserstring);
		if (!$syncReturn){
			print "zconf read error: Could not sync config to the loaded config.";
		};
	};
		
	return 1;
};

=head2 writeChooserFile

This function is a internal function and largely meant to only be called
writeChooser, which it functions the same as. It works on the file backend.

	#writes the contents of $chooserString to the chooser for "foo/bar"
	if(!$zconf->writeChooserFile("foo/bar", $chooserString)){
		print "it failed\n";
	};

	#does the same thing above, but using the error interface
	my $returned = $zconf->writeChooserFile("foo/bar", $chooserString)
	if($zconf->{error}){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	};

=cut

sub writeChooserFile{
	my ($self, $config, $chooserstring)= @_;

	$self->errorBlank;

	#return false if the config is not set
	if (!defined($config)){
		warn("zconf writeChooserFile:12: \$config is not defined");
		$self->{error}=17;
		$self->{errorString}='$config not defined';
		return undef;
	};

	#return false if the config is not set
	if (!defined($chooserstring)){
		warn("zconf writeChooserFile:12: \$chooserstring is not defined");
		$self->{error}=17;
		$self->{errorString}='\$chooserstring not defined';
		return undef;			
	};

	#make sure the config name is legit
	my ($error, $errorString)=$self->configNameCheck($config);
	if(defined($error)){
		warn("zconf writeChooserFile:12:".$error.": ".$errorString);
		$self->{error}=$error;
		$self->{errorString}=$errorString;
		return undef;
	};


	my $chooser=$self->{args}{base}."/".$config."/.chooser";

	#open the file and get the string error on not being able to open it 
	if(!open("WRITECHOOSER", ">", $chooser)){
		warn("zconf writeChooserFile:17: '".$self->{args}{base}."/".$config."/.chooser' open failed.");
		$self->{error}=15;
		$self->{errorString}="'".$self->{args}{base}."/".$config."/.chooser' open failed.";
	};
	print WRITECHOOSER $chooserstring;
	close("WRITECHOOSER");		

	return (1);
};

=head2 writeChooserLDAP

This function is a internal function and largely meant to only be called
writeChooser, which it functions the same as. It works on the LDAP backend.

	#writes the contents of $chooserString to the chooser for "foo/bar"
	if(!$zconf->writeChooserLDAP("foo/bar", $chooserString)){
		print "it failed\n";
	};

	#does the same thing above, but using the error interface
	my $returned = $zconf->writeChooserLDAP("foo/bar", $chooserString)
	if(defined($zconf->{error})){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	};

=cut

sub writeChooserLDAP{
	my ($self, $config, $chooserstring)= @_;

	$self->errorBlank;

	#return false if the config is not set
	if (!defined($config)){
		warn("zconf writeChooserLDAP:12: \$config is not defined");
		$self->{error}=17;
		$self->{errorString}='$config not defined';
		return undef;			
	};

	#return false if the config is not set
	if (!defined($chooserstring)){
		warn("zconf writeChooserLDAP:12: \$chooserstring is not defined");
		$self->{error}=17;
		$self->{errorString}='\$chooserstring not defined';
		return undef;
	};

	#make sure the config name is legit
	my ($error, $errorString)=$self->configNameCheck($config);
	if(defined($error)){
		warn("zconf writeChooserLDAP:12:".$error.": ".$errorString);
		$self->{error}=$error;
		$self->{errorString}=$errorString;
		return undef;
	};

	#checks to make sure the config does exist
	if(!$self->configExists($config)){
		warn("zconf writeChooserLDAP:12: '".$config."' does not exist.");
		$self->{error}=12;
		$self->{errorString}="'".$config."' does not exist.";
		return undef;			
	};

	if(defined($self->{error})){
		return undef;
	};

	#creates the DN from the config
	my $dn=$self->config2dn($config).",".$self->{args}{"ldap/base"};

	#connects to LDAP
	my $ldap=$self->LDAPconnect();
	if (defined($self->{error})) {
		warn('zconf writeSetFromLoadedConfigLDAP: LDAPconnect errored... returning...');
		return undef;
	}

	#gets the LDAP entry
	my $entry=$self->LDAPgetConfEntry($config, $ldap);
	#return upon error
	if (defined($self->{error})) {
		return undef;
	}

	if(!defined($entry->dn())){
		warn("zconf readChooserFromLDAP:13: Expected DN, '".$dn."' not found.");
		$self->{error}=13;
		$self->{errorString}="Expected DN, '".$dn."' not found.";
		return undef;
	}else{
		if($entry->dn ne $dn){
			warn("zconf readChooserFromLDAP:13: Expected DN, '".$dn."' not found.");
			$self->{error}=13;
			$self->{errorString}="Expected DN, '".$dn."' not found.";
			return undef;				
		};
	};

	#replace the zconfChooser entry and updated it
	$entry->replace(zconfChooser=>$chooserstring);
	$entry->update($ldap);

	return (1);
};


=head2 writeSetFromHash

This takes a hash and writes it to a config. It takes two arguements,
both of which are hashes.

The first hash has one required key, which is 'config', the name of the
config it is to be written to. If the 'set' is defined, that set will be
used.

The second hash is the hash to be written to the config.

	if(!$zconf->writeSetFromHash({config=>"foo/bar"}, %hash)){
		print "'foo/bar' does not exist\n";
	};

	#does the same thing above, but using the error interface
	my $returned = $zconf->writeSetFromHash({config=>"foo/bar"}, %hash)
	if(defined($zconf->{error})){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	};

=cut

#the overarching writeSetFromHash
sub writeSetFromHash{
	my $self=$_[0];
	my %args=%{$_[1]};
	my %hash = %{$_[2]};

	$self->errorBlank;

	#return false if the config is not set
	if (!defined($args{config})){
		warn("zconf writeSetFromHash:12: \$config is not defined");
		$self->{error}=17;
		$self->{errorString}='$config not defined';
		return undef;			
	};

	#make sure the config name is legit
	my ($error, $errorString)=$self->configNameCheck($args{config});
	if(defined($error)){
		warn("zconf writeSetFromHash:12:".$error.": ".$errorString);
		$self->{error}=$error;
		$self->{errorString}=$errorString;
		return undef;
	};
		
	#checks to make sure the config does exist
	if(!$self->configExists($args{config})){
		warn("zconf writeSetFromHash:12: '".$args{config}."' does not exist.");
		$self->{error}=12;
		$self->{errorString}="'".$args{config}."' does not exist.";
		return undef;			
	};

	#sets the set to default if it is not defined
	if (!defined($args{set})){
		$args{set}=$self->{args}{default};
	};

	my $returned=undef;

	#writes it
	if($self->{args}{backend} eq "file"){
		$returned=$self->writeSetFromHashFile(\%args, \%hash);
	}else{
		if($self->{args}{backend} eq "ldap"){
			$returned=$self->writeSetFromHashLDAP(\%args, \%hash);
		};
	};
		
	if(!$returned){
		return undef;
	};
		
	#attempt to sync the set locally if not using the file backend
	if($self->{args}{backend} ne "file"){
		my $syncReturn=$self->writeSetFromHashFile({config=>$args{config},set=>$args{set}}, \%hash);
		if (!$syncReturn){
				warn("zconf writeSetFromHash:9: Could not sync config to the loaded config.");
		};
	};

	return 1;
};

=head2 writeSetFromHashFile

This function is intended for internal use only and functions exactly like
writeSetFromHash, but functions just on the file backend.

	if(!$zconf->writeSetFromHashFile({config=>"foo/bar"}, %hash)){
		print "'foo/bar' does not exist\n";
	};

	#does the same thing above, but using the error interface
	my $returned = $zconf->writeSetFromHashFile({config=>"foo/bar"}, %hash)
	if($zconf->{error}){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	};

=cut

#write out a config from a hash to the file backend
sub writeSetFromHashFile{
	my $self = $_[0];
	my %args=%{$_[1]};
	my %hash = %{$_[2]};

	$self->errorBlank;

	#return false if the config is not set
	if (!defined($args{config})){
		warn("zconf writeChooserFile:12: \$config is not defined");
		$self->{error}=17;
		$self->{errorString}='$config not defined';
		return undef;			
	};

	#make sure the config name is legit
	my ($error, $errorString)=$self->configNameCheck($args{config});
	if(defined($error)){
		warn("zconf writeChooserFile:12:".$error.": ".$errorString);
		$self->{error}=$error;
		$self->{errorString}=$errorString;
		return undef;
	};
		
	#checks to make sure the config does exist
	if(!$self->configExists($args{config})){
		warn("zconf writeChooserFile:12: '".$args{config}."' does not exist.");
		$self->{error}=12;
		$self->{errorString}="'".$args{config}."' does not exist.";
		return undef;			
	};
		
	#the path to the file
	my $fullpath=$self->{args}{base}."/".$args{config}."/".$args{set};
	
	#get a list of keys
	my @hashkeys=keys(%hash);
		
	my $setstring="";
		
	#creates the string that contains the settings
	my $int=0;
	while(defined($hashkeys[$int])){
		if ($hashkeys[$int]=~/^ /){
			warn("zconf writeSetFromHashFile:19: '".$hashkeys[$int]."' key contains a ' '.");
			$self->{error}=19;
			$self->{errorString}="'".$hashkeys[$int]."' key contains a ' '.";
			return undef;
		};

		my $value=$hash{$hashkeys[$int]};

		#changes new lines into spaces followed by a new line
		$value=~ s/\n/\n /g;
			
		$setstring=$setstring.$hashkeys[$int]."=".$value."\n";
			
		$int++;
	};
		
	#opens the file and returns if it can not
	#creates it if necesary
	if(!open("THEFILE", '>', $fullpath)){
		warn("zconf writeChooserFile:17: '".$self->{args}{base}."/".$args{config}."/.chooser' open failed.");
		$self->{error}=15;
		$self->{errorString}="'".$self->{args}{base}."/".$args{config}."/.chooser' open failed.";
		return undef;
	};
	print THEFILE $setstring;
	close("THEFILE");
		
	return 1;
};

=head2 writeSetFromHashLDAP

This function is intended for internal use only and functions exactly like
writeSetFromHash, but functions just on the LDAP backend.

	if(!$zconf->writeSetFromHashLDAP({config=>"foo/bar"}, %hash)){
		print "'foo/bar' does not exist\n";
	};

	#does the same thing above, but using the error interface
	my $returned = $zconf->writeSetFromHashLDAP({config=>"foo/bar"}, %hash)
	if(defined($zconf->{error})){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	};

=cut

#write out a config from a hash to the LDAP backend
sub writeSetFromHashLDAP{
	my $self = $_[0];
	my %args=%{$_[1]};
	my %hash = %{$_[2]};

	$self->errorBlank;

	#return false if the config is not set
	if (!defined($args{config})){
		warn("zconf writeChooserFile:12: \$config is not defined");
		$self->{error}=17;
		$self->{errorString}='$config not defined';
		return undef;			
	};

	#make sure the config name is legit
	my ($error, $errorString)=$self->configNameCheck($args{config});
	if(defined($error)){
		warn("zconf writeChooserFile:12:".$error.": ".$errorString);
		$self->{error}=$error;
		$self->{errorString}=$errorString;
		return undef;
	};

	#checks to make sure the config does exist
	if(!$self->configExists($args{config})){
		warn("zconf writeChooserFile:12: '".$args{config}."' does not exist.");
		$self->{error}=12;
		$self->{errorString}="'".$args{config}."' does not exist.";
		return undef;			
	};

	#sets the set to default if it is not defined
	if (!defined($args{set})){
		$args{set}="default";
	};
		
	#sets the set to default if it is not defined
	if (!defined($args{autoCreateConfig})){
		$args{autoCreateConfig}="0";
	};
		
	#get a list of keys
	my @hashkeys=keys(%hash);
		
	my $setstring=$args{set}."\n";
		
	#creates the string that contains the settings
	my $int=0;
	while(defined($hashkeys[$int])){
		if ($hashkeys[$int]=~/^ /){
			warn("zconf writeSetFromHashFile:19: '".$hashkeys[$int]."' key contains a ' '.");
			$self->{error}=19;
			$self->{errorString}="'".$hashkeys[$int]."' key contains a ' '.";
			return undef;
		};

		my $value=$hash{$hashkeys[$int]};

		#changes new lines into spaces followed by a new line
		$value=~ s/\n/\n /g;
			
		$setstring=$setstring.$hashkeys[$int]."=".$value."\n";
			
		$int++;
	};

	#creates the DN from the config
	my $dn=$self->config2dn($args{config}).",".$self->{args}{"ldap/base"};

	#connects to LDAP
	my $ldap=$self->LDAPconnect();
	if (defined($self->{error})) {
		warn('zconf writeSetFromLoadedConfigLDAP: LDAPconnect errored... returning...');
		return undef;
	}

	#gets the LDAP entry
	my $entry=$self->LDAPgetConfEntry($args{config}, $ldap);
	#return upon error
	if (defined($self->{error})) {
		return undef;
	}
	
	if(!defined($entry->dn())){
		warn("zconf writeChooserLDAP:13: Expected DN, '".$dn."' not found.");
		$self->{error}=13;
		$self->{errorString}="Expected DN, '".$dn."' not found.";
		return undef;
	}else{
		if($entry->dn ne $dn){
			warn("zconf writeChooserLDAP:13: Expected DN, '".$dn."' not found.");
			$self->{error}=13;
			$self->{errorString}="Expected DN, '".$dn."' not found.";
			return undef;				
		};
	};
	
	#makes sure the zconfSet attribute is set for the config in question
	my @attributes=$entry->get_value('zconfSet');
	#if the 0th is not defined, it this zconf entry is borked and it needs to have the set value added 
	if(defined($attributes[0])){
		#if $attributes dues contain enteries, make sure that one of them is the proper set
		my $attributesInt=0;
		my $setFound=0;#set to one if the loop finds the set
		while(defined($attributes[$attributesInt])){
			if($attributes[$attributesInt] eq $args{set}){
				$setFound=1;
			};
			$attributesInt++;
		};
		#if the set was not found, add it
		if(!$setFound){
			$entry->add(zconfSet=>$args{set});
		};
	}else{
		$entry->add(zconfSet=>$args{set});
	}
	
	#
	@attributes=$entry->get_value('zconfData');
	#if the 0th is not defined, it this zconf entry is borked and it needs to have it added...  
	if(defined($attributes[0])){
		#if $attributes dues contain enteries, make sure that one of them is the proper set
		my $attributesInt=0;
		my $setFound=undef;#set to one if the loop finds the set
		while(defined($attributes[$attributesInt])){
			if($attributes[$attributesInt] =~ /^$args{set}\n/){
				#delete it the attribute and readd it, if it has not been found yet...
				#if it has been found it means this entry is borked and the duplicate
				#set needs removed...
				if(!$setFound){
					$entry->delete(zconfData=>[$attributes[$attributesInt]]);
					$entry->add(zconfData=>[$setstring]);
				}else{
					if($setstring ne $attributes[$attributesInt]){
						$entry->delete(zconfData=>[$attributes[$attributesInt]]);
					};
				};
				$setFound=1;
			};
			$attributesInt++;
		};
		#if the config is not found, add it
		if(!$setFound){
				$entry->add(zconfData=>[$setstring]);
		};
	}else{
		$entry->add(zconfData=>$setstring);
	}

	#write the entry to LDAP
	my $results=$entry->update($ldap);

	return 1;
};

=head2 writeSetFromLoadedConfig

This function writes a loaded config to a to a set.

One arguement is required, which is a hash. 'config' is the one
required key in the hash and it represents the config that should
be written out to a set. 'set' is a optional key that represents
set the config will be written to. If there is not set defined,
the current set will be used.

	if(!$zconf->writeSetFromLoadedConfig({config=>"foo/bar"})){
		print "it failed\n";
	};

	#does the same thing above, but using the error interface
	my $returned = $zconf->writeSetFromLoadedConfig({config=>"foo/bar"}, %hash)
	if(defined($zconf->{error})){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	};

=cut

#the overarching writeSetFromLoadedConfig
sub writeSetFromLoadedConfig{
	my $self=$_[0];
	my %args= %{$_[1]};

	#return false if the config is not set
	if (!defined($args{config})){
		warn("zconf writeSetFromLoadedConfig:12: \$config is not defined");
		$self->{error}=17;
		$self->{errorString}='$config not defined';
		return undef;			
	};

	if(!defined($self->{conf}{$args{config}})){
		warn("zconf regexVarSearch:25: Config '".$args{config}."' is not loaded.");
		$self->{error}=25;
		$self->{errorString}="Config '".$args{config}."' is not loaded.";
		return undef;
	};

	#sets the set to default if it is not defined
	if (!defined($args{set})){
		$args{set}=$self->{set}{$args{config}};
	}else{
		if($self->setNameLegit($args{set})){
			$self->{args}{default}=$args{set};
		}else{
			warn("zconf writeSetFromLoadedConfig:27: '".$args{set}."' is not a legit set name.");
			$self->{error}=27;
			$self->{errorString}="'".$args{set}."' is not a legit set name.";
			return undef
		};
	};

	my $returned=undef;

	#writes it
	if($self->{args}{backend} eq "file"){
		$returned=$self->writeSetFromLoadedConfigFile(\%args);
	}else{
		if($self->{args}{backend} eq "ldap"){
			$returned=$self->writeSetFromLoadedConfigLDAP(\%args);
		};
	};
		
	if(!$returned){
		return undef;
	};

	#attempt to sync the set locally if not using the file backend
	if($self->{args}{backend} ne "file"){
		my $syncReturn=$self->writeSetFromLoadedConfigFile(\%args);
		if (!$syncReturn){
			print "zconf read error: Could not sync config to the loaded config.";
		};
	};

	return 1;
};

=head2 writeSetFromLoadedConfigFile

This is a internal only function. No checking is done on the arguements
as that is done in writeSetFromLoadedConfig. This provides the file
backend for writeSetFromLoadedConfig.

	if(!$zconf->writeSetFromLoadedConfigFile({config=>"foo/bar"})){
		print "it failed\n";
	};

	#does the same thing above, but using the error interface
	my $returned = $zconf->writeSetFromLoadedConfigFile({config=>"foo/bar"}, %hash)
	if($zconf->{error}){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	};

=cut

#write a set out
sub writeSetFromLoadedConfigFile{
	my $self = $_[0];
	my %args=%{$_[1]};
		
	#the path to the file
	my $fullpath=$self->{args}{base}."/".$args{config}."/".$args{set};

	#get a list of keys
	my @hashkeys=keys(%{$self->{conf}{$args{config}}});

	my $setstring="";

	#create the ZML object
	my $zml=ZML->new();

	my $hashkeysInt=0;#used for intering through the list of hash keys
	#builds the ZML object
	while(defined($hashkeys[$hashkeysInt])){
		#attempts to add the variable
		$zml->addVar($hashkeys[$hashkeysInt], 
					$self->{conf}{$args{config}}{$hashkeys[$hashkeysInt]});
		#checks to verify there was no error
		#this is not a fatal error... skips it if it is not legit
		if(defined($zml->{error})){
			warn('zconf writeSetFromLoadedConfigLDAP:23: $zml->addMeta() returned '.
				$zml->{error}.", '".$zml->{errorString}."'. Skipping variable '".
				$hashkeys[$hashkeysInt]."' in '".$args{config}."'.");
		};
			
		$hashkeysInt++;
	};

	#opens the file and returns if it can not
	#creates it if necesary
	if(!open("THEFILE", '>', $fullpath)){
		warn("zconf writeChooserFile:17: '".$self->{args}{base}."/".$args{config}."/.chooser' open failed.");
		$self->{error}=15;
		$self->{errorString}="'".$self->{args}{base}."/".$args{config}."/.chooser' open failed.";
		return undef;
	};
	print THEFILE $zml->string();
	close("THEFILE");

	return 1;
};

=head2 writeSetFromLoadedConfigLDAP

This is a internal only function. No checking is done on the arguements
as that is done in writeSetFromLoadedConfig. This provides the LDAP
backend for writeSetFromLoadedConfig.

	if(!$zconf->writeSetFromLoadedConfigLDAP({config=>"foo/bar"})){
		print "it failed\n";
	};

	#does the same thing above, but using the error interface
	my $returned = $zconf->writeSetFromLoadedConfigLDAP({config=>"foo/bar"}, %hash)
	if(defined($zconf->{error})){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	};

=cut

#write a set out to LDAP
sub writeSetFromLoadedConfigLDAP{
	my $self = $_[0];
	my %args=%{$_[1]};

	#get a list of keys
	my @hashkeys=keys(%{$self->{conf}{$args{config}}});

	#create the ZML object
	my $zml=ZML->new();
		
	my $hashkeysInt=0;#used for intering through the list of hash keys
	#builds the ZML object
	while(defined($hashkeys[$hashkeysInt])){
		#attempts to add the variable
		$zml->addVar($hashkeys[$hashkeysInt], 
					$self->{conf}{$args{config}}{$hashkeys[$hashkeysInt]});
		#checks to verify there was no error
		#this is not a fatal error... skips it if it is not legit
		if(defined($zml->{error})){
			warn('zconf writeSetFromLoadedConfigLDAP:23: $zml->addMeta() returned '.
				$zml->{error}.", '".$zml->{errorString}."'. Skipping variable '".
				$hashkeys[$hashkeysInt]."' in '".$args{config}."'.");
		};
			
		$hashkeysInt++;
	};

	my $setstring=$args{set}."\n".$zml->string();

	#creates the DN from the config
	my $dn=$self->config2dn($args{config}).",".$self->{args}{"ldap/base"};

	#connects to LDAP
	my $ldap=$self->LDAPconnect();
	if (defined($self->{error})) {
		warn('zconf writeSetFromLoadedConfigLDAP: LDAPconnect errored... returning...');
		return undef;
	}

	#gets the LDAP entry
	my $entry=$self->LDAPgetConfEntry($args{config}, $ldap);
	#return upon error
	if (defined($self->{error})) {
		return undef;
	}

	if(!defined($entry->dn())){
		warn("zconf writeChooserLDAP:13: Expected DN, '".$dn."' not found.");
		$self->{error}=13;
		$self->{errorString}="Expected DN, '".$dn."' not found.";
		return undef;
	}else{
		if($entry->dn ne $dn){
			warn("zconf writeChooserLDAP:13: Expected DN, '".$dn."' not found.");
			$self->{error}=13;
			$self->{errorString}="Expected DN, '".$dn."' not found.";
			return undef;				
		};
	};

	#makes sure the zconfSet attribute is set for the config in question
	my @attributes=$entry->get_value('zconfSet');
	#if the 0th is not defined, it this zconf entry is borked and it needs to have the set value added 
	if(defined($attributes[0])){
		#if $attributes dues contain enteries, make sure that one of them is the proper set
		my $attributesInt=0;
		my $setFound=0;#set to one if the loop finds the set
		while(defined($attributes[$attributesInt])){
			if($attributes[$attributesInt] eq $args{set}){
				$setFound=1;
			};
			$attributesInt++;
		};
		#if the set was not found, add it
		if(!$setFound){
			$entry->add(zconfSet=>$args{set});
		};
	}else{
		$entry->add(zconfSet=>$args{set});
	};

	#
	@attributes=$entry->get_value('zconfData');
	#if the 0th is not defined, it this zconf entry is borked and it needs to have it added...  
	if(defined($attributes[0])){
		#if $attributes dues contain enteries, make sure that one of them is the proper set
		my $attributesInt=0;
		my $setFound=undef;#set to one if the loop finds the set
		while(defined($attributes[$attributesInt])){
			if($attributes[$attributesInt] =~ /^$args{set}\n/){
				#delete it the attribute and readd it, if it has not been found yet...
				#if it has been found it means this entry is borked and the duplicate
				#set needs removed...
				if(!$setFound){
					$entry->delete(zconfData=>[$attributes[$attributesInt]]);
					$entry->add(zconfData=>[$setstring]);
				}else{
					if($setstring ne $attributes[$attributesInt]){
						$entry->delete(zconfData=>[$attributes[$attributesInt]]);
					};
				};
				$setFound=1;
			};
			$attributesInt++;
		};
		#if the config is not found, add it
		if(!$setFound){
			$entry->add(zconfData=>[$setstring]);
		};
	}else{
		$entry->add(zconfData=>$setstring);
	}
	my $results=$entry->update($ldap);

	return 1;
};

=head1 CONFIG NAME

Any configuration name is legit as long as it does not match any of the following.

	undef
	/./
	/\/\./
	/\.\.\//
	/\/\//
	/\.\.\//
	/\/\.\./
	/^\.\//
	/\/$/
	/^\//
	/\n/

=head1 SET NAME

Any set name is legit as long as it does not match any of the following.

	undef
	/\//
	/^\./
	/^ /
	/ $/
	/\.\./

=head1 VARIABLE NAME

Any variable name is legit as long it does not match any of the following.

	/,/
	/\/\./
	/\/\//
	\.\.\//
	/\/\.\./
	/^\.\//
	/\/$/	
	/^\//
	/\n/
	/=/

=head1 ERROR CODES

Since version '0.6.0' any time '$zconf->{error}' is true, there is an error.

=head2 1

config name contains ,

=head2 2

config name contains /.

=head2 3

config name contains //

=head2 4

config name contains ../

=head2 5

config name contains /..

=head2 6

config name contains ^./

=head2 7

config name ends in /

=head2 8

config name starts with /

=head2 9

could not sync to file

=head2 10

config name contains a \n

=head2 11

LDAP entry already exists

=head2 12

config does not exist

=head2 13

Expected LDAP DN not found

=head2 14

file/dir does not exist

=head2 15

file/dir open failed

=head2 16

file/dir creation failed

=head2 17

file write failed

=head2 18

improper function usage

=head2 19

config key starts with a ' '

=head2 20

LDAP entry has no sets

=head2 21

set not found for config

=head2 22

LDAPmakepathSimple failed

=head2 23

skilling variable as it is not a legit name

=head2 24

set is not defined

=head2 25

Config is undefined.

=head2 26

Config not loaded.

=head2 27

Set name is not a legit name.

=head2 28

ZML->parse error.

=head2 29

Could not unlink the unlink the set.

=head2 30

The sets exist for the specified config.

=head2 31

Did not find a matching set.

=head2 32

Unable to choose a set.

=head2 33

Unable to remove the config as it has sub configs.

=head2 34

LDAP connection error

=head2 35

Can't use system mode and file together.

=head1 ERROR CHECKING

This can be done by checking $zconf->{error} to see if it is defined. If it is defined,
The number it contains is the corresponding error code. A description of the error can also
be found in $zconf->{errorString}, which is set to "" when there is no error.

=head1 INTERNALS

ZConf stores the object information in a hash. The keys are 'conf', 'args', 'zconf',
'user', 'error', and 'errorString'.

=head2 conf

This is a hash whose keys represent various configs. Each item in the hash is another hash.
Each key of that a value in a config.

=head2 args

This is the arguements currently in use by ZConf.

=head2 zconf

This is the parsed configuration settings for ZConf as pulled from xdg_config_home()."/zconf.zml".

=head2 error

This is contains the error code if there is an error. It is undefined when none is present.

=head2 errorString

This contains a description of the error when one is present. When one is not present it is "".

=head2 set

This contains a hash, whose keys are the name of the loaded configs. The value of each key
is the name of the loaded set for that config.

=head1 zconf.zml

The default is 'xdf_config_home/zconf.zml', which is generally '~/.config/zconf.zml'. See perldoc
ZML for more information on the file format. The keys are listed below.

=head2 General Keys

=head3 backend

This is the backend to use for storage. Current values of 'file' and 'ldap' are supported.

=head3 backendChooser

This is a Chooser string that chooses what backend should be used.

=head3 defaultChooser

This is a chooser string that chooses what the name of the default to use should be.

=head3 fileonly

This is a boolean value. If it is set to 1, only the file backend is used.

=head2 readfallthrough

If this is set, if any of the functions below error when trying the LDAP backend, it will
fall through to the file backend.

    configExists
    getAvailableSets
    getSubConfigs
    read
    readChooser

=head2 LDAP Backend Keys

=head3 LDAPprofileChooser

This is a chooser string that chooses what LDAP profile to use. If this is not present, 'default'
will be used for the profile.

=head3 ldap/<profile>/bind

This is the DN to bind to the server as.

=head3 ldap/<profile>/homeDN

This is the home DN of the user in question. The user needs be able to write to it. ZConf
will attempt to create 'ou=zconf,ou=.config,$homeDN' for operating out of.

=head3 ldap/<profile>/host

This is the server to use for LDAP connections.

=head3 ldap/<profile>/password

This is the password to use for when connecting to the server.

=head1 ZConf LDAP Schema

	# 1.3.6.1.4.1.26481 Zane C. Bowers
	#  .2 ldap
	#   .7 zconf
	#    .0 zconfData
	#    .1 zconfChooser
	#    .2 zconfSet
	
	attributeType ( 1.3.6.1.4.1.26481.2.7.0
		NAME 'zconfData'
		DESC 'Data attribute for a zconf entry.'
		SYNTAX 1.3.6.1.4.1.1466.115.121.1.15
		EQUALITY caseExactMatch
		)
	
	attributeType ( 1.3.6.1.4.1.26481.2.7.1
		NAME 'zconfChooser'
		DESC 'Chooser attribute for a zconf entry.'
		SYNTAX 1.3.6.1.4.1.1466.115.121.1.15
		EQUALITY caseExactMatch
		)
	
	attributeType ( 1.3.6.1.4.1.26481.2.7.2
		NAME 'zconfSet'
		DESC 'A zconf set name available in a entry.'
		SYNTAX 1.3.6.1.4.1.1466.115.121.1.15
		EQUALITY caseExactMatch
		)

	objectclass ( 1.3.6.1.4.1.26481.2.7
		NAME 'zconf'
		DESC 'A zconf entry.'
		MAY ( cn $ zconfData $ zconfChooser $ zconfSet )
		)

=head1 SYSTEM MODE

This is for deamons or the like. This will read
'/var/db/zconf/$sys/zconf.zml' for it's options and store
the file backend stuff in '/var/db/zconf/$sys/zconf/'.

=head1 UTILITIES

These are installed with the module.

=head2 zccreate

Used for creating empty config or set.

=head3 -c <config>

The config to be created.

=head3 -s <set>

The set to be created. This is an optional option.

=head2 zcget

This fetches the value for a variable.

=head3 -c <config>

The config to be used for fetching the key.

=head3 -k <key>

This is the key to get.

=head3 -n

Do not print a newline.

=head3 -s <set>

The set to be created. If it is not specified, the default will
be used.

=head2 zcls

This lists subconfigs.

=head3 -c <config>

The config to list the subconfigs of. If '-c ""' is used, it will
show the base ones.

=head3 -s

IF this is specified, the sets of the config will be listed.

=head2 zcrm

This removes a config or set.

=head3 -c <config>

This is the config to be removed.

=head3 -s <set>

If this is specified, the config is not removed, but the specified set for
the specified config.

=head2 zcset

This sets a specified value for a variable.

=head3 -c <config>

This is the config to be operated on.

=head3 -k <variable>

This is the key to set.

=head3 -s <set>

This is the set to operate on. If it is not defined, it will be default
will be used.

=head3 -v <value>

The value of set the key to.

=head2 zcvdel

This deletes a variable.

=head3 -c <config>

This is the config to be operated on.

=head3 -k <variable>

This is the key to be removed.

=head3 -s <set>

This is the set to operate on. If it is not defined, it will be default
will be used.

=head2 zcvls

This shows the variables in a config.

=head3 -c <config>

This is the config to be operated on.

=head3 -s <set>

This is the set to operate on. If it is not defined, it will be default
will be used.

=head1 AUTHOR

Zane C. Bowers, C<< <vvelox at vvelox.net> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-zconf at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=ZConf>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc ZConf


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=ZConf>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/ZConf>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/ZConf>

=item * Search CPAN

L<http://search.cpan.org/dist/ZConf>

=back


=head1 ACKNOWLEDGEMENTS


=head1 COPYRIGHT & LICENSE

Copyright 2009 Zane C. Bowers, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.


=cut

1; # End of ZConf
