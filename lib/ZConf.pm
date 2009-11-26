package ZConf;

use Net::LDAP;
use Net::LDAP::LDAPhash;
use Net::LDAP::Makepath;
use File::Path;
use File::BaseDir qw/xdg_config_home/;
use Chooser;
use warnings;
use strict;
use ZML;
use Sys::Hostname;

=head1 NAME

ZConf - A configuration system allowing for either file or LDAP backed storage.

=head1 VERSION

Version 2.0.1

=cut

our $VERSION = '2.0.1';

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

	my $zconf=ZConf->(\%args);

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
	my $function='new';

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
	#meta holds meta variable information
	my $self = {conf=>{}, args=>{%args}, set=>{}, zconf=>{}, user=>{}, error=>undef,
				errorString=>"", meta=>{}, comment=>{}, module=>__PACKAGE__,
				revision=>{}, locked=>{}, autoupdateGlobal=>1, autoupdate=>{}};
	bless $self;

	if (defined($self->{args}{file}) && defined($self->{args}{sysmode})) {
		$self->{error}=35;
		$self->{errorString}='sys and file can not be specified together';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#sets the base directory
	if (!defined($self->{args}{sys})) {
		$self->{args}{base}=xdg_config_home()."/zconf/";
	}else {
		$self->{args}{base}='/var/db/zconf/'.$self->{args}{sys};

		#make sure it will only be one directory
		if ($self->{args}{sys} =~ /\//) {
				$self->{error}='38';
				$self->{errorString}='Sys name,"'.$self->{args}{base}.'", matches /\//';
				warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
				return $self;
		}

		#make sure it is not hidden
		if ($self->{args}{sys} =~ /\./) {
				$self->{error}='39';
				$self->{errorString}='Sys name,"'.$self->{args}{base}.'", matches /\./';
				warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
				return $self;
		}

		#make sure the system directory exists
		if (!-d '/var/db/zconf') {
			if (!mkdir('/var/db/zconf')) {
				$self->{error}='36';
				$self->{errorString}='Could not create "/var/db/zconf/"';
				warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
				return $self;
			}
		}

		#make sure the 
		if (!-d $self->{args}{base}) {
			if (!mkdir($self->{args}{base})) {
				$self->{error}='37';
				$self->{errorString}='Could not create "'.$self->{args}{base}.'"';
				warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
				return $self;
			}
		}
	}

	#set the config file if it is not already set
	if(!defined($self->{args}{file})){
		$self->{args}{file}=xdg_config_home()."/zconf.zml";
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
			}
		}
	}

	#do something if the base directory does not exist
	if(! -d $self->{args}{base}){
		#if the base diretory can not be created, exit
		if(!mkdir($self->{args}{base})){
			print "zconf new error: '".$self->{args}{base}.
			      "' does not exist and could not be created.\n";
			return undef;
		}
	}

	my $zconfzmlstring="";#holds the contents of zconf.zml
	#returns undef if it can't read zconf.zml
	if(open("READZCONFZML", $self->{args}{file})){
		$zconfzmlstring=join("", <READZCONFZML>);
		my $tempstring;
		close("READZCONFZML");
	}else{
		print "zconf new error: Could not open'".$self->{args}{file}."\n";
		return undef;
	}

	#tries to parse the zconf.zml
	my $zml=ZML->new();
	$zml->parse($zconfzmlstring);
	if($zml->{error}){
#		$self->{error}=28;
#		$self->{errorString}="ZML\-\>parse error, '".$zml->{error}."', '".$zml->{errorString}."'";
#		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}
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
			}
		}else{
			$self->{args}{default}="default";
		}
	}else{
		if(defined($self->{zconf}{default})){
			$self->{args}{default}=$self->{zconf}{default};
		}else{
			$self->{args}{default}="default";
		}
	}
		
	#get what the file only arg should be
	#this is a Perl boolean value
	if(!defined($self->{zconf}{fileonly})){
		$self->{zconf}->{args}{fileonly}="0";
	}else{
		$self->{args}{fileonly}=$self->{zconf}{fileonly};
	}

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
				}
			}
		}else{
			if(defined($self->{zconf}{backend})){
				$self->{args}{backend}=$self->{zconf}{backend};
			}else{
				$self->{args}{backend}="file";
			}
		}
	}else{
		$self->{args}{backend}="file";
	}
		
	#make sure the backend is legit
	my @backends=("file", "ldap");
	my $backendLegit=0;
	my $backendsInt=0;
	while(defined($backends[$backendsInt])){
		if ($backends[$backendsInt] eq $self->{args}{backend}){
			$backendLegit=1;
		}

		$backendsInt++;
	}

	if(!$backendLegit){
		warn("zconf new error: The backend '".$self->{args}{backend}.
			 "' is not a recognized backend.\n");
		return undef;
	}
		
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
			}
		}else{
			#if LDAPprofile is defined, use it, if not set it to default
			if(defined($self->{zconf}{LDAPprofile})){
				$self->{args}{LDAPprofile}=$self->{zconf}{LDAPprofile};
			}else{
				$self->{args}{LDAPprofile}="default";
			}
		}

		#gets the host
		if(defined($self->{zconf}{"ldap/".$self->{args}{LDAPprofile}."/host"})){
			$self->{args}{"ldap/host"}=$self->{zconf}{"ldap/".$self->{args}{LDAPprofile}."/host"};
		}else{
			#sets it to localhost if not defined
			$self->{args}{"ldap/host"}="127.0.0.1"
		}

		#gets the capath
		if(defined($self->{zconf}{"ldap/".$self->{args}{LDAPprofile}."/capath"})){
			$self->{args}{"ldap/capath"}=$self->{zconf}{"ldap/".$self->{args}{LDAPprofile}."/capath"};
		}else{
			#sets it to localhost if not defined
			$self->{args}{"ldap/capath"}=undef;
		}

		#gets the cafile
		if(defined($self->{zconf}{"ldap/".$self->{args}{LDAPprofile}."/cafile"})){
			$self->{args}{"ldap/cafile"}=$self->{zconf}{"ldap/".$self->{args}{LDAPprofile}."/cafile"};
		}else{
			#sets it to localhost if not defined
			$self->{args}{"ldap/cafile"}=undef;
		}

		#gets the checkcrl
		if(defined($self->{zconf}{"ldap/".$self->{args}{LDAPprofile}."/checkcrl"})){
			$self->{args}{"ldap/checkcrl"}=$self->{zconf}{"ldap/".$self->{args}{LDAPprofile}."/checkcrl"};
		}else{
			#sets it to localhost if not defined
			$self->{args}{"ldap/checkcrl"}=undef;
		}

		#gets the clientcert
		if(defined($self->{zconf}{"ldap/".$self->{args}{LDAPprofile}."/clientcert"})){
			$self->{args}{"ldap/clientcert"}=$self->{zconf}{"ldap/".$self->{args}{LDAPprofile}."/clientcert"};
		}else{
			#sets it to localhost if not defined
			$self->{args}{"ldap/clientcert"}=undef;
		}

		#gets the clientkey
		if(defined($self->{zconf}{"ldap/".$self->{args}{LDAPprofile}."/clientkey"})){
			$self->{args}{"ldap/clientkey"}=$self->{zconf}{"ldap/".$self->{args}{LDAPprofile}."/clientkey"};
		}else{
			#sets it to localhost if not defined
			$self->{args}{"ldap/clientkey"}=undef;
		}

		#gets the starttls
		if(defined($self->{zconf}{"ldap/".$self->{args}{LDAPprofile}."/starttls"})){
			$self->{args}{"ldap/starttls"}=$self->{zconf}{"ldap/".$self->{args}{LDAPprofile}."/starttls"};
		}else{
			#sets it to localhost if not defined
			$self->{args}{"ldap/starttls"}=undef;
		}

		#gets the TLSverify
		if(defined($self->{zconf}{"ldap/".$self->{args}{LDAPprofile}."/TLSverify"})){
			$self->{args}{"ldap/TLSverify"}=$self->{zconf}{"ldap/".$self->{args}{LDAPprofile}."/TLSverify"};
		}else{
			#sets it to localhost if not defined
			$self->{args}{"ldap/TLSverify"}='none';
		}

		#gets the SSL version to use
		if(defined($self->{zconf}{"ldap/".$self->{args}{LDAPprofile}."/SSLversion"})){
			$self->{args}{"ldap/SSLversion"}=$self->{zconf}{"ldap/".$self->{args}{LDAPprofile}."/SSLversion"};
		}else{
			#sets it to localhost if not defined
			$self->{args}{"ldap/SSLversion"}='tlsv1';
		}

		#gets the SSL ciphers to use
		if(defined($self->{zconf}{"ldap/".$self->{args}{LDAPprofile}."/SSLciphers"})){
			$self->{args}{"ldap/SSLciphers"}=$self->{zconf}{"ldap/".$self->{args}{LDAPprofile}."/SSLciphers"};
		}else{
			#sets it to localhost if not defined
			$self->{args}{"ldap/SSLciphers"}='ALL';
		}

		#gets the password value to use
		if(defined($self->{zconf}{"ldap/".$self->{args}{LDAPprofile}."/password"})){
			$self->{args}{"ldap/password"}=$self->{zconf}{"ldap/".$self->{args}{LDAPprofile}."/password"};
		}else{
			#sets it to localhost if not defined
			$self->{args}{"ldap/password"}="";
		}

		#gets the password value to use
		if(defined($self->{zconf}{"ldap/".$self->{args}{LDAPprofile}."/passwordfile"})){
			$self->{args}{"ldap/passwordfile"}=$self->{zconf}{"ldap/".$self->{args}{LDAPprofile}."/passwordfile"};
			if (open( PASSWORDFILE,  $self->{args}{"ldap/passwordfile"} )) {
				$self->{args}{"ldap/password"}=join( "\n", <PASSWORDFILE> );
				close(PASSWORDFILE);
			}else {
				warn($self->{module}.' '.$function.': Failed to open the password file, "'.
					 $self->{args}{"ldap/passwordfile"}.'",');
			}
		}

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
		}

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
		}

		#this holds the DN that is the base for everything done
		$self->{args}{"ldap/base"}="ou=zconf,ou=.config,".$self->{args}{"ldap/homeDN"};
		
		#tests the connection
		my $ldap=$self->LDAPconnect;
		if ($self->{error}) {
			warn('ZConf new: LDAPconnect errored');
			return undef;
		}

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
			}
		}

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
			}
		}
		
		#disconnects from the LDAP server
		$ldap->unbind;
	}

	return $self;
}

=head2 chooseSet

This chooses what set should be used using the associated chooser
string for the config in question.

This function does fail safely. If a improper configuration is returned by
chooser string, it uses the value the default set.

It takes one arguement, which is the configuration it is for.

If the chooser errors, is blank, or is just a newline, the default is
returned.

	my $set=$zconf->chooseSet("foo/bar");
    if($zconf->{error}){
        print "Error!\n";
    }

=cut

#the overarching function for getting available sets
sub chooseSet{
	my ($self, $config) = @_;
	my $function='chooseSet';

	$self->errorBlank;

	my ($error, $errorString)=$self->configNameCheck($config);
	if(defined($error)){
		$self->{error}=$error;
		$self->{errorString}=$errorString;
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	my $chooserstring=$self->readChooser($config);

	#makes sure it is not blank
	if ($chooserstring eq '') {
		return $self->{args}{default};
	}
	#makes sure it is not just a new line
	if ($chooserstring eq "\n") {
		return $self->{args}{default};
	}
	
	my ($success, $choosen)=choose($chooserstring);
	
	if(!defined( $choosen )){
		return $self->{args}{default};
	}
	
	if (!$self->setNameLegit($choosen)){
		$self->{error}=27;
		$self->{errorString}='"'.$choosen."' is not a legit set name. Using the".
		                     " default of '".$self->{args}{default}."'.";
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return $self->{args}{default};
	}
	
	return $choosen;
}

=head2 config2dn

This function converts the config name into part of a DN string. IT
is largely only for internal use and is used by the LDAP backend.

	my $partialDN = $zconf->config2dn("foo/bar");
    if($zconf->{error}){
        print "Error!\n";
    }

=cut

#converts the config to a DN
sub config2dn(){
	my $self=$_[0];
	my $config=$_[1];
	my $function='config2dn';

	$self->errorBlank;

	if ($config eq '') {
		return '';
	}

	my ($error, $errorString)=$self->configNameCheck($config);
	if(defined($error)){
		$self->{error}=$error;
		$self->{errorString}=$errorString;
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

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
		}
			
		$int++;
	}
		
	return $dn;
}

=head2 configExists

This function is used for checking if a config exists or not.

It takes one option, which is the configuration to check for.

The returned value is a perl boolean value.

    $zconf->configExists("foo/bar")
	if($zconf->{error}){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	}

=cut

#check if a config exists
sub configExists{
	my ($self, $config) = @_;
	my $function='configExists';

	$self->errorBlank;

	my ($error, $errorString)=$self->configNameCheck($config);
	if(defined($error)){
		$self->{error}=$error;
		$self->{errorString}=$errorString;
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	my $returned=undef;

	#run the checks
	if($self->{args}{backend} eq "file"){
		$returned=$self->configExistsFile($config);
	}else{
		if($self->{args}{backend} eq "ldap"){
			$returned=$self->configExistsLDAP($config);
		}
		#if it errors and read fall through is turned on, try the file backend
		if ($self->{error}&&$self->{args}{readfallthrough}) {
			$self->errorBlank;
			$returned=$self->configExistsFile($config);
		}
	}

	if(!$returned){
		return undef;
	}

	return 1;
}

=head2 configExistsFile

This function functions exactly the same as configExists, but
for the file backend.

No config name checking is done to verify if it is a legit name or not
as that is done in configExists. The same is true for calling errorBlank.

    $zconf->configExistsFile("foo/bar")
	if($zconf->{error}){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	}

=cut

#checks if a file config exists 
sub configExistsFile{
	my ($self, $config) = @_;
	my $function='configExistsFile';

	$self->errorBlank;

	#makes the path if it does not exist
	if(!-d $self->{args}{base}."/".$config){
		return 0;
	}
		
	return 1;
}

=head2 configExistsLDAP

This function functions exactly the same as configExists, but
for the LDAP backend.

No config name checking is done to verify if it is a legit name or not
as that is done in configExists. The same is true for calling errorBlank.

    $zconf->configExistsLDAP("foo/bar")
	if($zconf->{error}){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	}

=cut

#check if a LDAP config exists
sub configExistsLDAP{
	my ($self, $config) = @_;
	my $function='configExistsLDAP';

	$self->errorBlank;

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
	}

	return 1;
}

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
	my $function='configNameCheck';

	$self->errorBlank;

	#checks for undef
	if(!defined($name)){
		return("11", "config name is not defined.");
	}

	#checks for ,
	if($name =~ /,/){
		return("1", "config name,'".$name."', contains ','");
	}

	#checks for /.
	if($name =~ /\/\./){
		return("2", "config name,'".$name."', contains '/.'");
	}

	#checks for //
	if($name =~ /\/\//){
		return("3", "config name,'".$name."', contains '//'");
	}

	#checks for ../
	if($name =~ /\.\.\//){
		return("4", "config name,'".$name."', contains '../'");
	}

	#checks for /..
	if($name =~ /\/\.\./){
		return("5", "config name,'".$name."', contains '/..'");
	}

	#checks for ^./
	if($name =~ /^\.\//){
		return("6", "config name,'".$name."', matched /^\.\//");
	}

	#checks for /$
	if($name =~ /\/$/){
		return("7", "config name,'".$name."', matched /\/$/");
	}

	#checks for ^/
	if($name =~ /^\//){
		return("8", "config name,'".$name."', matched /^\//");
	}

	#checks for ^/
	if($name =~ /\n/){
		return("10", "config name,'".$name."', matched /\\n/");
	}

	return(undef, "");
}

=head2 createConfig

This function is used for creating a new config. 

One arguement is needed and that is the config name.

The returned value is a perl boolean.

    $zconf->createConfig("foo/bar")
	if($zconf->{error}){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	};

=cut

#the overarching function for getting available sets
sub createConfig{
	my ($self, $config) = @_;
	my $function='createConfig';

	$self->errorBlank;

	my ($error, $errorString)=$self->configNameCheck($config);
	if(defined($error)){
		$self->{error}=$error;
		$self->{errorString}=$errorString;
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	my $returned=undef;

	#create the config
	if($self->{args}{backend} eq "file"){
		$returned=$self->createConfigFile($config);
	}else{
		if($self->{args}{backend} eq "ldap"){
			$returned=$self->createConfigLDAP($config);
		};
	}

	if(!$returned){
		return undef;
	}

	#attempt to sync the config locally if not using the file backend
	if($self->{args}{backend} ne "file"){
		#if it does not exist, add it
		if(!$self->configExistsFile($config)){
			my $syncReturn=$self->createConfigFile($config);
			if (!$syncReturn){
				$self->{error}=10;
				$self->{errorString}="zconf createConfig: Syncing to file failed for '".$config."'.";
				warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
			}
		}
	}

	return 1;
}

=head2 createConfigFile

This functions just like createConfig, but is for the file backend.
This is not really meant for external use. The config name passed
is not checked to see if it is legit or not.

    $zconf->createConfigFile("foo/bar")
	if($zconf->{error}){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	};

=cut

#creates a new config file as well as the default set
sub createConfigFile{
	my ($self, $config) = @_;
	my $function='createConfigFile';

	$self->errorBlank;

	#makes the path if it does not exist
	if(!mkpath($self->{args}{base}."/".$config)){
		$self->{error}=16;
		$self->{errorString}="'".$self->{args}{base}."/".$config."' creation failed.";
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	return 1;
}

=head2 createConfigLDAP

This functions just like createConfig, but is for the LDAP backend.
This is not really meant for external use. The config name passed
is not checked to see if it is legit or not.

    $zconf->createConfigLDAP("foo/bar")
	if($zconf->{error}){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	};

=cut

#creates a new LDAP enty if it is not defined
sub createConfigLDAP{
	my ($self, $config) = @_;
	my $function='createConfigLDAP';

	$self->errorBlank;

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
			$self->{errorString}="zconf createLDAPConfig:22: Adding '".$dn."' failed when executing LDAPmakepathSimple.\n";
			$self->{error}=22;
			warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
			return undef;
		}
	}else{
		$self->{error}=11;
		$self->{errorString}=" DN '".$dn."' already exists.";
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;

	}
	return 1;
}



=head2 defaultSetExists

This checks to if the default set for a config exists. It takes one arguement,
which is the name of the config. The returned value is a Perl boolean.

    my $returned=$zconf->defaultSetExists('someConfig');
    if($zconf->{error}){
        print "Error!\n";
    }
    if($returned){
        print "It exists.\n";
    }

=cut

sub defaultSetExists{
	my $self=$_[0];
	my $config=$_[1];
	my $function='defaultSetExists';

	$self->errorBlank();

	#make sure the config name is legit
	my ($error, $errorString)=$self->configNameCheck($config);
	if(defined($error)){
		$self->{error}=$error;
		$self->{errorString}=$errorString;
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#makes sure it exists
	if (!$self->configExists($config)){
		$self->{error}=12;
		$self->{errorString}='The specified config, "'.$config.'" does not exist';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
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
	my $function='delConfig';

	$self->errorBlank;
	
	#return if no set is given
	if (!defined($config)) {
		$self->{error}=25;
		$self->{errorString}='$config not defined';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#makes sure no subconfigs exist
	my @subs=$self->getSubConfigs($config);
	#return if this can't be completed
	if (defined($self->{error})) {
		return undef;		
	}
	if (defined($subs[0])) {
		$self->{error}=33;
		$self->{errorString}='Could not remove the config as it has sub configs.';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#do it
	my $returned;
	if ($self->{args}{backend} eq "file") {
		$returned=$self->delConfigFile($config);
	} else {
		if ($self->{args}{backend} eq "ldap") {
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
	my $function='delConfigFile';

	$self->errorBlank;

	#return if this can't be completed
	if (defined($self->{error})) {
		return undef;		
	}

	my @subs=$self->getSubConfigsFile($config);
	#return if there are any sub configs
	if (defined($subs[0])) {
		$self->{error}='33';
		$self->{errorString}='Could not remove the config as it has sub configs';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#makes sure it exists before continuing
	#This will also make sure the config exists.
	my $returned = $self->configExistsFile($config);
	if (defined($self->{error})){
		$self->{error}='12';
		$self->{errorString}='The config, "'.$config.'", does not exist';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
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
		$self->{error}=29;
		$self->{errorString}='"'.$configpath.'" could not be unlinked.';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	return 1;
}

=head2 delConfigLDAP

This removes a config. Any sub configs will need to removes first. If any are
present, this function will error.

    #removes 'foo/bar'
    $zconf->delConfig('foo/bar');
    if($zconf->{error}){
        print 'error!';
    }

=cut

sub delConfigLDAP{
	my $self=$_[0];
	my $config=$_[1];
	my $function='delConfigLDAP';

	$self->errorBlank;

	my @subs=$self->getSubConfigsFile($config);
	#return if there are any sub configs
	if (defined($subs[0])) {
		$self->{error}='33';
		$self->{errorString}='Could not remove the config as it has sub configs';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#makes sure it exists before continuing
	#This will also make sure the config exists.
	my $returned = $self->configExistsLDAP($config);
	if (defined($self->{error})){
		$self->{error}='12';
		$self->{errorString}='The config, "'.$config.'", does not exist';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#connects up to LDAP... will be used later
	my $ldap=$self->LDAPconnect();
	
	#gets the DN and use $ldap since it is already setup
	my $entry=$self->LDAPgetConfEntry($config, $ldap);

	#if $entry is undefined, it was not found
	if (!defined($entry)){
		$self->{error}='13';
		$self->{errorString}='The expected DN was not found';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#remove it
	$entry->delete();
	$entry->update($ldap);

	#return if it could not be removed
	if($ldap->error()){
		$self->{error}='34';
		$self->{errorString}=' Could not delete the LDAP entry, "'.
							$entry->dn().'". LDAP return an error of "'.$ldap->error.
							'" and an error code of "'.$ldap->errcode.'"';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	return 1;
}

=head2 delSet

This deletes a specified set.

Two arguements are required. The first one is the name of the config and the and
the second is the name of the set.

    $zconf->delSetFile("foo/bar", "someset");
    if($zconf->{error}){
        print "delSet failed\n";
    }

=cut

sub delSet{
	my $self=$_[0];
	my $config=$_[1];
	my $set=$_[2];
	my $function='delSet';
	
	$self->errorBlank;

	#return if no set is given
	if (!defined($set)){
		$self->{error}=24;
		$self->{errorString}='$set not defined';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#return if no config is given
	if (!defined($config)){
		$self->{error}=25;
		$self->{errorString}='$config not defined';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#makes sure it exists before continuing
	#This will also make sure the config exists.
	my $returned = $self->configExists($config);
	if (defined($self->{error})){
		$self->{error}=12;
		$self->{errorString}='The config "'.$config.'" does not exist';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
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

    $zconf->delSetFile("foo/bar", "someset");
    if($zconf->{error}){
        print "delSet failed\n";
    }

=cut

sub delSetFile{
	my $self=$_[0];
	my $config=$_[1];
	my $set=$_[2];
	my $function='delSetFile';

	$self->errorBlank;

	#return if no set is given
	if (!defined($set)){
		$self->{error}=24;
		$self->{errorString}='$set not defined';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#return if no config is given
	if (!defined($config)){
		$self->{error}=25;
		$self->{errorString}='$config not defined';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#the path to the config
	my $configpath=$self->{args}{base}."/".$config;

	#returns with an error if it could not be set
	if (!-d $configpath) {
		$self->{error}=14;
		$self->{errorString}='"'.$config.'" is not a directory or does not exist';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}
	
	#the path to the set
	my $fullpath=$configpath."/".$set;

	if (!unlink($fullpath)) {
		$self->{error}=29;
		$self->{errorString}='"'.$fullpath.'" could not be unlinked.';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	return 1;
}

=head2 delSetLDAP

This deletes a specified set, for the LDAP backend.

Two arguements are required. The first one is the name of the config and the and
the second is the name of the set.

    $zconf->delSetLDAP("foo/bar", "someset");
    if($zconf->{error}){
        print "delSet failed\n";
    }


=cut

sub delSetLDAP{
	my $self=$_[0];
	my $config=$_[1];
	my $set=$_[2];
	my $function='delSetLDAP';

	$self->errorBlank;

	#return if no config is given
	if (!defined($config)){
		$self->{error}=25;
		$self->{errorString}='$config not defined';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
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
		$self->{error}=13;
		$self->{errorString}="Expected DN, '".$dn."' not found.";
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}else{
		if($entry->dn ne $dn){
			$self->{error}=13;
			$self->{errorString}="Expected DN, '".$dn."' not found.";
			warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
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
			$self->{error}=31;
			$self->{errorString}='The specified set, "'.$set.'" was not found for "'.$config.'".';
			warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
			return undef;
		}
	}else{
		$self->{error}=30;
		$self->{errorString}='No zconfData attributes exist for "'.$dn.'" and thus no sets exist.';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
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

=head2 getAutoupdate

This gets if a config should be automatically updated or not.

One arguement is required and it is the config. If this is undefined
or a matching one is not found, the global is used.

The return value is a boolean.

    #fetches the global
    my $autoupdate=$zconf->getAutoupdate();

    #fetches it for 'some/config'
    my $autoupdate=$zconf->getAutoupdate('some/config');

=cut

sub getAutoupdate{
	my $self=$_[0];
	my $config=$_[1];

	$self->errorBlank;

	if (!defined( $config )) {
		return $self->{autoupdateGlobal};
	}

	if (defined( $self->{autoupdate}{$config} )) {
		return $self->{autoupdate}{$config};
	}

	return $self->{autoupdateGlobal};
}

=head2 getAvailableSets

This gets the available sets for a config.

The only arguement is the name of the configuration in question.

	my @sets = $zconf->getAvailableSets("foo/bar");
	if($zconf->{error}){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	}

=cut

#the overarching function for getting available sets
sub getAvailableSets{
	my ($self, $config) = @_;
	my $function='getAvailableSets';

	$self->errorBlank();

	#make sure the config name is legit
	my ($error, $errorString)=$self->configNameCheck($config);
	if(defined($error)){
		$self->{error}=$error;
		$self->{errorString}=$errorString;
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#checks to make sure the config does exist
	if(!$self->configExists($config)){
		$self->{error}=12;
		$self->{errorString}="'".$config."' does not exist.";
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;			
	}

	my @returned=undef;

	#get the sets
	if($self->{args}{backend} eq "file"){
		@returned=$self->getAvailableSetsFile($config);
	}else{
		if($self->{args}{backend} eq "ldap"){
			@returned=$self->getAvailableSetsLDAP($config);
		}
		#if it errors and read fall through is turned on, try the file backend
		if ($self->{error}&&$self->{args}{readfallthrough}) {
			$self->errorBlank;
			@returned=$self->getAvailableSetsFile($config);
		}
	}

	return @returned;
}

=head2 getAvailableSetsFile

This is exactly the same as getAvailableSets, but for the file back end.
For the most part it is not intended to be called directly.

	my @sets = $zconf->getAvailableSetsFile("foo/bar");
	if($zconf->{error}){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	}

=cut

#this gets a set for a given file backed config
sub getAvailableSetsFile{
	my ($self, $config) = @_;
	my $function='getAvailableSetsFile';

	$self->errorBlank;

	#returns 0 if the config does not exist
	if (!-d $self->{args}{base}."/".$config) {
		$self->{error}=14;
		$self->{errorString}="'".$self->{args}{base}."/".$config."' does not exist.";
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	if (!opendir(CONFIGDIR, $self->{args}{base}."/".$config)) {
		$self->{error}=15;
		$self->{errorString}="'".$self->{args}{base}."/".$config."' open failed.";
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}
	my @direntries=readdir(CONFIGDIR);
	closedir(CONFIGDIR);

	#remove hidden files and directory recursors from @direntries
	@direntries=grep(!/^\./, @direntries);
	@direntries=grep(!/^\.\.$/, @direntries);
	@direntries=grep(!/^\.$/, @direntries);

	my @sets=();

	#go though the list and return only files
	my $int=0;
	while (defined($direntries[$int])) {
		if (-f $self->{args}{base}."/".$config."/".$direntries[$int]) {
			push(@sets, $direntries[$int]);
		}
		$int++;
	}

	return @sets;
}

=head2 getAvailableSetsLDAP

This is exactly the same as getAvailableSets, but for the file back end.
For the most part it is not intended to be called directly.

	my @sets = $zconf->getAvailableSetsLDAP("foo/bar");
	if($zconf->{error}){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	}

=cut

sub getAvailableSetsLDAP{
	my ($self, $config) = @_;
	my $function='getAvailableSetsLDAP';

	$self->errorBlank;

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
		$self->{error}=13;
		$self->{errorString}="Expected DN, '".$dn."' not found.";
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}
		
	my $setint=0;
	my @sets=();
	while(defined($hashedmesg{$dn}{ldap}{zconfSet}[$setint])){
		$sets[$setint]=$hashedmesg{$dn}{ldap}{zconfSet}[$setint];
		$setint++;
	}
		
	return @sets;
}

=head2 getDefault

This gets the default set currently being used if one is not choosen.

	my $defaultSet = $zml->getDefault();

=cut
	
#gets what the default set is
sub getDefault{
	my ($self)= @_;

	$self->errorBlank;

	return $self->{args}{default};
}

=head2 getComments

This gets a list of variables that have comments.

	my @keys = $zconf->getComments("foo/bar")
	if($zconf->{error}){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	}

=cut

#get a list of keys for a config
sub getComments {
	my ($self, $config) = @_;
	my $function='getComments';

	$self->errorBlank;

	#update if if needed
	$self->updateIfNeeded({config=>$config, clearerror=>1, autocheck=>1});

	if(!defined($self->{comment}{$config})){
		$self->{error}=26;
		$self->{errorString}="Config '".$config."' is not loaded.";
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	my @keys=keys(%{$self->{comment}{$config}});

	return @keys;
}

=head2 getConfigRevision

This fetches the revision for the speified config.

    my $revision=$zconf->getConfigRevision('some/config');
    if($zconf->{error}){
        print "Error!\n";
    }

=cut

sub getConfigRevision{
	my $self=$_[0];
	my $config=$_[1];
	my $function='getConfigRevision';

	$self->errorBlank;

	#return false if the config is not set
	if (!defined($config)){
		$self->{error}=25;
		$self->{errorString}='No config specified';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#checks to make sure the config does exist
	if(!$self->configExists($config)){
		$self->{error}=12;
		$self->{errorString}="'".$config."' does not exist.";
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;			
	}

	my $returned=undef;
		
	#loads the config
	if($self->{args}{backend} eq "file"){
		$returned=$self->getConfigRevisionFile($config);
	}else{
		if($self->{args}{backend} eq "ldap"){
			$returned=$self->getConfigRevisionLDAP($config);
		}
		#if it errors and read fall through is turned on, try the file backend
		if ($self->{error}&&$self->{args}{readfallthrough}) {
			$self->errorBlank;
			$returned=$self->getConfigRevisionFile($config);
			#we return here because if we don't we will pointlessly sync it
			return $returned;
		}
	}

	return $returned;
}

=head2 getConfigRevisionFile

This fetches the revision for the speified config using
the file backend.

A return of undef means that the config has no sets created for it
yet or it has not been read yet by 2.0.0 or newer.

    my $revision=$zconf->getConfigRevision('some/config');
    if($zconf->{error}){
        print "Error!\n";
    }
    if(!defined($revision)){
        print "This config has had no sets added since being created or is from a old version of ZConf.\n";
    }

=cut

sub getConfigRevisionFile{
	my $self=$_[0];
	my $config=$_[1];
	my $function='getConfigRevisionFile';

	$self->errorBlank;

	#return false if the config is not set
	if (!defined($config)){
		$self->{error}=25;
		$self->{errorString}='No config specified';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#checks to make sure the config does exist
	if(!$self->configExistsFile($config)){
		$self->{error}=12;
		$self->{errorString}="'".$config."' does not exist.";
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;			
	}

	#
	my $revisionfile=$self->{args}{base}."/".$config."/.revision";

	my $revision;
	if ( -f $revisionfile) {
		if(!open("THEREVISION", '<', $revisionfile)){
			warn($self->{module}.' '.$function.':43: '."'".$revisionfile."' open failed");
		}
		$revision=join('', <THEREVISION>);
		close(THEREVISION);
	}

	return $revision;
}

=head2 getConfigRevisionLDAP

This fetches the revision for the speified config using
the LDAP backend.

A return of undef means that the config has no sets created for it
yet or it has not been read yet by 2.0.0 or newer.

    my $revision=$zconf->getConfigRevision('some/config');
    if($zconf->{error}){
        print "Error!\n";
    }
    if(!defined($revision)){
        print "This config has had no sets added since being created or is from a old version of ZConf.\n";
    }

=cut

sub getConfigRevisionLDAP{
	my $self=$_[0];
	my $config=$_[1];
	my $function='getConfigRevisionLDAP';

	$self->errorBlank;

	#return false if the config is not set
	if (!defined($config)){
		$self->{error}=25;
		$self->{errorString}='No config specified';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#checks to make sure the config does exist
	if(!$self->configExistsFile($config)){
		$self->{error}=12;
		$self->{errorString}="'".$config."' does not exist.";
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;			
	}

	#gets the LDAP entry
	my $entry=$self->LDAPgetConfEntry($config);
	#return upon error
	if ($self->{error}) {
		warn($self->{module}.' '.$function.': LDAPgetConfEntry errored');
		return undef;
	}

	#gets the revisions
	my @revs=$entry->get_value('zconfRev');
	if (!defined($revs[0])) {
		return undef;
	}

	return $revs[0];
}

=head2 getCtime

This fetches the mtime for a variable.

Two arguements are required. The first is the config
and the second is the variable.

The returned value is UNIX time value for when it was last
changed. If it is undef, it means the variable has not been
changed since ZConf 2.0.0 came out.

    my $time=$zconf->getMtime('some/config', 'some/var');
    if($zconf->{error}){
        print "Error!\n";
    }
    if(defined($time)){
        print "variable modified at".$time." seconds past 1970-01-01.\n";
    }else{
        print "variable not modifined since ZConf 2.0.0 came out.\n";
    }

=cut

sub getCtime{
	my $self=$_[0];
	my $config=$_[1];
	my $var=$_[2];
	my $function='getCtime';

	$self->errorBlank;

	#update if if needed
	$self->updateIfNeeded({config=>$config, clearerror=>1, autocheck=>1 });

	#return false if the config is not set
	if (!defined($config)){
		$self->{error}=25;
		$self->{errorString}='$config not defined';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;			
	}

	if(!defined($self->{conf}{$config})){
		$self->{error}=25;
		$self->{errorString}="Config '".$config."' is not loaded.";
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#no metas for this var
	if (!defined( $self->{meta}{$config}{$var} )) {
		return undef;
	}

	if (!defined( $self->{meta}{$config}{$var}{'ctime'} )) {
		return undef;
	}

	return $self->{meta}{$config}{$var}{'ctime'};
}

=head2 getKeys

This gets gets the keys for a loaded config.

	my @keys = $zconf->getKeys("foo/bar")
	if($zconf->{error}){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	}

=cut

#get a list of keys for a config
sub getKeys {
	my ($self, $config) = @_;
	my $function='getKeys';

	$self->errorBlank;

	#update if if needed
	$self->updateIfNeeded({config=>$config, clearerror=>1, autocheck=>1 });

	if(!defined($self->{conf}{$config})){
		$self->{error}=26;
		$self->{errorString}="Config '".$config."' is not loaded.";
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	my @keys=keys(%{$self->{conf}{$config}});

	return @keys;
}

=head2 getLoadedConfigRevision

This gets the revision of the specified config,
if it is loaded.

    my $rev=$zconf->getLoadedConfigRevision;
    if($zconf->{error}){
        print "Error!\n";
    }

=cut

sub getLoadedConfigRevision{
	my $self=$_[0];
	my $config=$_[1];
	my $function='getLoadedConfigRevision';

	$self->errorBlank;

	#return false if the config is not set
	if (!defined($config)){
		$self->{error}=25;
		$self->{errorString}='No config specified';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#make sure it is loaded
	if(!defined($self->{conf}{$config})){
		$self->{error}=26;
		$self->{errorString}="Config '".$config."' is not loaded.";
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	return $self->{revision}{$config};
}

=head2 getLoadedConfigs

This gets gets the keys for a loaded config.

	my @configs = $zconf->getLoadedConfigs("foo/bar")
	if($zconf->{error}){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	}

=cut

#get a list loaded configs
sub getLoadedConfigs {
	my ($self, $config) = @_;

	$self->errorBlank;

	my @keys=keys(%{$self->{conf}});

	return @keys;
}

=head2 getMetas

This gets a list of variables that have meta
variables.

	my @keys = $zconf->getComments("foo/bar")
	if($zconf->{error}){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	}

=cut

#get a list of keys for a config
sub getMetas {
	my ($self, $config) = @_;
	my $function='getMetas';

	$self->errorBlank;

	#update if if needed
	$self->updateIfNeeded({config=>$config, clearerror=>1, autocheck=>1 });

	if(!defined($self->{meta}{$config})){
		$self->{error}=26;
		$self->{errorString}="Config '".$config."' is not loaded.";
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	my @keys=keys(%{$self->{meta}{$config}});

	return @keys;
}

=head2 getMtime

This fetches the mtime for a variable.

Two arguements are required. The first is the config
and the second is the variable.

The returned value is UNIX time value for when it was last
changed. If it is undef, it means the variable has not been
changed since ZConf 2.0.0 came out.

    my $time=$zconf->getMtime('some/config', 'some/var');
    if($zconf->{error}){
        print "Error!\n";
    }
    if(defined($time)){
        print "variable modified at".$time." seconds past 1970-01-01.\n";
    }else{
        print "variable not modifined since ZConf 2.0.0 came out.\n";
    }

=cut

sub getMtime{
	my $self=$_[0];
	my $config=$_[1];
	my $var=$_[2];
	my $function='getMtime';

	$self->errorBlank;

	#update if if needed
	$self->updateIfNeeded({config=>$config, clearerror=>1, autocheck=>1 });

	#return false if the config is not set
	if (!defined($config)){
		$self->{error}=25;
		$self->{errorString}='$config not defined';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;			
	}

	if(!defined($self->{conf}{$config})){
		$self->{error}=25;
		$self->{errorString}="Config '".$config."' is not loaded.";
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#no metas for this var
	if (!defined( $self->{meta}{$config}{$var} )) {
		return undef;
	}

	if (!defined( $self->{meta}{$config}{$var}{'mtime'} )) {
		return undef;
	}

	return $self->{meta}{$config}{$var}{'mtime'};
}

=head2 getOverrideChooser

This will get the current override chooser for a config.

If no chooser is specified for the loaded config

One arguement is required it is the name of the config.

This method is basically a wrapper around regexMetaGet.

    my $orchooser=$zconf->getOverrideChooser($config);
    if($zconf->{error}){
        print "Error!\n";
    }

=cut

sub getOverrideChooser{
	my $self=$_[0];
	my $config=$_[1];
	my $function='getOverrideChooser';

	#blank the any previous errors
	$self->errorBlank;

	#return false if the config is not set
	if (!defined($config)){
		$self->{error}=25;
		$self->{errorString}='$config not defined';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;			
	}

	#make sure the loaded config is not locked
	if (defined( $self->{locked}{ $config } )) {
		$self->{error}=45;
		$self->{errorString}='The config "'.$config.'" is locked';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	my $chooser;

	if ( (defined( $self->{meta}{$config}{zconf} ))&&(defined( $self->{meta}{$config}{zconf}{'override/chooser'} )) ) {
		$chooser=$self->{meta}{$config}{zconf}{'override/chooser'};
	}

	return $chooser;
}

=head2 getSet

This gets the set for a loaded config.

	my $set = $zconf->getSet("foo/bar")
	if($zconf->{error}){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	}

=cut

#get the set a config is currently using
sub getSet{
	my ($self, $config)= @_;
	my $function='getSet';

	$self->errorBlank;

	if(!defined($self->{set}{$config})){
		$self->{error}=26;
		$self->{errorString}="Set '".$config."' is not loaded.";
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}
	
	return $self->{set}{$config};
}

=head2 getSubConfigs

This gets any sub configs for a config. "" can be used to get a list of configs
under the root.

One arguement is accepted and that is the config to look under.

    #lets assume 'foo/bar' exists, this would return
    my @subConfigs=$zconf->getSubConfigs("foo");
    if($zconf->{error}){
        print "There was some error.\n";
    }

=cut

#gets the configs under a config
sub getSubConfigs{
	my ($self, $config)= @_;
	my $function='getSubConfigs';

	#blank any previous errors
	$self->errorBlank;

	#make sure the config name is legit
	my ($error, $errorString)=$self->configNameCheck($config);
	if(defined($error)){
		$self->{error}=$error;
		$self->{errorString}=$errorString;
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
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
    if($zconf->{error}){
        print "There was some error.\n";
    }

=cut

#gets the configs under a config
sub getSubConfigsFile{
	my ($self, $config)= @_;
	my $function='getSubConfigsFile';

	$self->errorBlank;

	#returns 0 if the config does not exist
	if(!-d $self->{args}{base}."/".$config){
		$self->{error}=14;
		$self->{errorString}="'".$self->{args}{base}."/".$config."' does not exist.";
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	if(!opendir(CONFIGDIR, $self->{args}{base}."/".$config)){
		$self->{error}=15;
		$self->{errorString}="'".$self->{args}{base}."/".$config."' open failed.";
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}
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
	}

	return @sets;
}

=head2 getSubConfigsLDAP

This gets any sub configs for a config. "" can be used to get a list of configs
under the root.

One arguement is accepted and that is the config to look under.

    #lets assume 'foo/bar' exists, this would return
    my @subConfigs=$zconf->getSubConfigs("foo");
    if($zconf->{error}){
        print "There was some error.\n";
    }

=cut

#gets the configs under a config
sub getSubConfigsLDAP{
	my ($self, $config)= @_;
	my $function='getSubConfigsLDAP';

	$self->errorBlank;

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

=head2 isLoadedConfigLocked

This returns if the loaded config is locked or not.

Only one arguement is taken and that is the name of the config.

    my $returned=$zconf->isLoadedConfigLocked('some/config');
    if($zconf->{error}){
        print "Error!\n";
    }

=cut

sub isLoadedConfigLocked{
	my $self=$_[0];
	my $config=$_[1];
	my $function='isLoadedConfigLocked';

	$self->errorBlank;

	#return false if the config is not set
	if (!defined($config)){
		$self->{error}=25;
		$self->{errorString}='No config specified';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#make sure it is loaded
	if(!defined($self->{conf}{$config})){
		$self->{error}=26;
		$self->{errorString}="Config '".$config."' is not loaded.";
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	if (defined($self->{locked}{$config})) {
		return 1;
	}

	return undef;
}

=head2 isConfigLocked

This checks if a config is locked or not.

One arguement is required and it is the name of the config.

The returned value is a boolean value.

    my $locked=$zconf->isConfigLocked('some/config');
    if($zconf->{error}){
        print "Error!\n";
    }
    if($locked){
        print "The config is locked\n";
    }

=cut

sub isConfigLocked{
	my $self=$_[0];
	my $config=$_[1];
	my $function='isConfigLocked';

	$self->errorBlank;

	#return false if the config is not set
	if (!defined($config)){
		$self->{error}=25;
		$self->{errorString}='No config specified';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#makes sure it exists
	my $exists=$self->configExists($config);
    if ($self->{error}) {
		warn($self->{module}.' '.$function.': configExists errored');
		return undef;
	}
	if (!$exists) {
		$self->{error}=12;
		$self->{errorString}='The config, "'.$config.'", does not exist';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	my $returned=undef;

	#locks the config
	if($self->{args}{backend} eq "file"){
		$returned=$self->isConfigLockedFile($config);
	}else{
		if($self->{args}{backend} eq "ldap"){
			$returned=$self->isConfigLockedLDAP($config);
		}
		#handle it if it errored
		if ($self->{error}&&$self->{args}{readfallthrough}) {
			$self->errorBlank;
			$returned=$self->isConfigLockedFile($config);
			#we return here because if we don't we will pointlessly sync it
			return $returned;
		}

		#sync it
		$self->lockConfigFile($config);
	}
	
	return $returned;
}

=head2 isConfigLockedFile

This checks if a config is locked or not for the file backend.

One arguement is required and it is the name of the config.

The returned value is a boolean value.

    my $locked=$zconf->isConfigLockedFile('some/config');
    if($zconf->{error}){
        print "Error!\n";
    }
    if($locked){
        print "The config is locked\n";
    }

=cut

sub isConfigLockedFile{
	my $self=$_[0];
	my $config=$_[1];
	my $function='isConfigLockedFile';

	$self->errorBlank;

	#return false if the config is not set
	if (!defined($config)){
		$self->{error}=25;
		$self->{errorString}='No config specified';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#makes sure it exists
	my $exists=$self->configExists($config);
    if ($self->{error}) {
		warn($self->{module}.' '.$function.': configExists errored');
		return undef;
	}
	if (!$exists) {
		$self->{error}=12;
		$self->{errorString}='The config, "'.$config.'", does not exist';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#checks if it is
	my $lockfile=$self->{args}{base}."/".$config."/.lock";
	if (-e $lockfile) {
		#it is locked
		return 1;
	}

	return undef;
}

=head2 isConfigLockedLDAP

This checks if a config is locked or not for the LDAP backend.

One arguement is required and it is the name of the config.

The returned value is a boolean value.

    my $locked=$zconf->isConfigLockedLDAP('some/config');
    if($zconf->{error}){
        print "Error!\n";
    }
    if($locked){
        print "The config is locked\n";
    }

=cut

sub isConfigLockedLDAP{
	my $self=$_[0];
	my $config=$_[1];
	my $function='isConfigLockedLDAP';

	$self->errorBlank;

	#return false if the config is not set
	if (!defined($config)){
		$self->{error}=25;
		$self->{errorString}='No config specified';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#makes sure it exists
	my $exists=$self->configExists($config);
    if ($self->{error}) {
		warn($self->{module}.' '.$function.': configExists errored');
		return undef;
	}
	if (!$exists) {
		$self->{error}=12;
		$self->{errorString}='The config, "'.$config.'", does not exist';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	my $entry=$self->LDAPgetConfEntry($config);
	#return upon error
	if ($self->{error}) {
		warn($self->{module}.' '.$function.': LDAPgetConfEntry errored');
		return undef;
	}

	#check if it is locked or not
	my @locks=$entry->get_value('zconfRev');
	if (defined($locks[0])) {
		#it is locked
		return 1;
	}

	#it is not locked
	return undef;
}

=head2 LDAPconnect

This generates a Net::LDAP object based on the LDAP backend.

    my $ldap=$zconf->LDAPconnect();
    if($zconf->{error}){
        print "error!";
    }

=cut

sub LDAPconnect{
	my $self=$_[0];
	my $function='LDAPconnect';

	$self->errorBlank;

	#connects up to LDAP
	my $ldap=Net::LDAP->new(
							$self->{args}{"ldap/host"},
							port=>$self->{args}{"ldap/port"},
							);

	#make sure we connected
	if (!$ldap) {
		$self->{error}=1;
		$self->{errorString}='Failed to connect to LDAP';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#start tls stuff if needed
	my $mesg;
	if ($self->{args}{"ldap/starttls"}) {
		$mesg=$ldap->start_tls(
							   verify=>$self->{args}{'larc/TLSverify'},
							   sslversion=>$self->{args}{'ldap/SSLversion'},
							   ciphers=>$self->{args}{'ldap/SSLciphers'},
							   cafile=>$self->{args}{'ldap/cafile'},
							   capath=>$self->{args}{'ldap/capath'},
							   checkcrl=>$self->{args}{'ldap/checkcrl'},
							   clientcert=>$self->{args}{'ldap/clientcert'},
							   clientkey=>$self->{args}{'ldap/clientkey'},
							   );

		if (!$mesg->{errorMessage} eq '') {
			$self->{error}=1;
			$self->{errorString}='$ldap->start_tls failed. $mesg->{errorMessage}="'.
			                     $mesg->{errorMessage}.'"';
			warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
			return undef;
		}
	}

	#bind
	$mesg=$ldap->bind($self->{args}{"ldap/bind"},
					  password=>$self->{args}{"ldap/password"},
					  );
	if (!$mesg->{errorMessage} eq '') {
		$self->{error}=13;
		$self->{errorString}='Binding to the LDAP server failed. $mesg->{errorMessage}="'.
		                     $mesg->{errorMessage}.'"';
		warn('Plugtools connect:13: '.$self->{errorString});
		return undef;
	}

	return $ldap;
}

=head2 LDAPgetConfMessage

Gets a Net::LDAP::Message object that was created doing a search for the config with
the scope set to base.

    #gets it for 'foo/bar'
    my $mesg=$zconf->LDAPgetConfMessage('foo/bar');
    #gets it using $ldap for the connection
    my $mesg=$zconf->LDAPgetConfMessage('foo/bar', $ldap);
    if($zconf->{error}){
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
    if($zconf->{error}){
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
    if($zconf->{error}){
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

=head2 override

This runs the overrides for a config.

This overrides various variables in the config by
running the chooser stored in '#!zconf=override/chooser'.
If it fails, the profile 'default' is used.

Once a profile name has been picked, everything under
'#!zconf=override/profiles/<profile>/' has
/^override\/profiles\/<profile>\// removed and it is
set as a regular variable.

One arguement is taken and it is a hash.

If a value of undef is returned, but no error is set, no
'#!zconf=override/chooser' is not defined.

=head3 args hash

=head4 config

This is the config to operate on.

=head4 profile

If this is not specified, the chooser stored
in the meta is '#!zconf=override/chooser'.

=cut

sub override{
	my $self=$_[0];
	my %args;
	if (defined($_[1])) {
		%args=%{$_[1]};
	}
	my $function='override';

	#blank the any previous errors
	$self->errorBlank;

	#update if if needed
	$self->updateIfNeeded({config=>$args{config}, clearerror=>1, autocheck=>1});

	#return false if the config is not set
	if (!defined($args{config})){
		$self->{error}=25;
		$self->{errorString}='$args{config} not defined';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;			
	}

	#make sure the loaded config is not locked
	if (defined( $self->{locked}{ $args{config} } )) {
		$self->{error}=45;
		$self->{errorString}='The config "'.$args{config}.'" is locked';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#make sure the config is loaded
	if(!defined( $self->{conf}{ $args{config} } )){
		$self->{error}=26;
		$self->{errorString}="Config '".$args{config}."' is not loaded.";
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#if no profile is given, get one
	if (!defined( $args{profile} )) {
		if ( (defined( $self->{meta}{$args{config}}{zconf} ))&&
			 (defined( $self->{meta}{$args{config}}{zconf}{'override/chooser'} ))
			) {

			my $chooser=$self->{meta}{$args{config}}{zconf}{'override/chooser'};
			#if the chooser is not blank, run it
			if ($chooser ne '') {
				my ($success, $choosen)=choose($chooser);

				#if no choosen name is returned, use 'default'
				if ($success) {
					$args{profile}=$choosen;
				}else {
					$args{profile}='default';
				}
			}else {
				$args{profile}='default';
			}
		}else {
			#none to process
			return undef;
		}
	}

	#make sure it is legit
	if (!$self->setNameLegit($args{profile})){
		$self->{error}=27;
		$self->{errorString}='"'.$args{profile}.'" is not a valid set name';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#
	my %metas=$self->regexMetaGet({
									config=>$args{config},
									varRegex=>'^zconf$',
									metaRegex=>'^override\/profiles\/'.quotemeta($args{profile}).'\/',
									});

	#this does definitely exist as it would have returned previously.
	my @keys=keys( %{ $metas{zconf} } );

	#processes each one
	my $int=0;
	while (defined( $keys[$int] )) {
		my $override=$keys[$int];

		my $remove='^override\/profiles\/'.quotemeta($args{profile}).'\/';

		$override=s/$override//g;

		$self->{conf}{$args{config}}{$override}=$self->{meta}{$args{config}}{'zconf'}{$keys[$int]};

		$int++;
	}
	
	return 1;
}

=head2 read

This reads a config. The only accepted option is the config name.

It takes one arguement, which is a hash.

=head3 hash args

=head4 config

The config to load.

=head4 override

This specifies if override should be ran not.

If this is not specified, it defaults to 1, true.

=head4 set

The set for that config to load.

    $zconf->read({config=>"foo/bar"})
	if($zconf->{error}){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	}

=cut

#the overarching read
sub read{
	my $self=$_[0];
	my %args=%{$_[1]};
	my $function='read';

	$self->errorBlank;

	#return false if the config is not set
	if (!defined($args{config})){
		$self->{error}=25;
		$self->{errorString}='No config specified';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#make sure the config name is legit
	my ($error, $errorString)=$self->configNameCheck($args{config});
	if(defined($error)){
		$self->{error}=$error;
		$self->{errorString}=$errorString;
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#checks to make sure the config does exist
	if(!$self->configExists($args{config})){
		$self->{error}=12;
		$self->{errorString}="'".$args{config}."' does not exist.";
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;			
	}

	#gets the set to use if not set
	if(!defined($args{set})){
		$args{set}=$self->chooseSet($args{config});
		if (defined($self->{error})) {
			$self->{error}='32';
			$self->{errorString}='Unable to choose a set';
			warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
			return undef;
		}
	}

	my $returned=undef;
		
	#loads the config
	if($self->{args}{backend} eq "file"){
		$returned=$self->readFile(\%args);
	}else{
		if($self->{args}{backend} eq "ldap"){
			$returned=$self->readLDAP(\%args);
		}
		#if it errors and read fall through is turned on, try the file backend
		if ($self->{error}&&$self->{args}{readfallthrough}) {
			$self->errorBlank;
			$returned=$self->readFile(\%args);
			#we return here because if we don't we will pointlessly sync it
			return $returned;
		}
	}
		
	if(!$returned){
		return undef;
	}
		
	#attempt to sync the config locally if not using the file backend
	if($self->{args}{backend} ne "file"){
		my $syncReturn;
		if (!$self->configExistsFile($args{config})) {
			$syncReturn=$self->createConfigFile($args{config});
			if (!$syncReturn){
				warn($self->{module}.' '.$function.': sync failed');
			}
		}
		$syncReturn=$self->writeSetFromLoadedConfigFile(\%args);
		if (!$syncReturn){
			print "zconf read error: Could not sync config to the loaded config.";
		}
	}

	return 1;
}

=head2 readFile

readFile functions just like read, but is mainly intended for internal use
only. This reads the config from the file backend.

=head3 hash args

=head4 config

The config to load.

=head4 override

This specifies if override should be ran not.

If this is not specified, it defaults to 1, true.

=head4 set

The set for that config to load.

    $zconf->readFile({config=>"foo/bar"})
	if($zconf->{error}){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	}

=cut

#read a config from a file
sub readFile{
	my $self=$_[0];
	my %args=%{$_[1]};
	my $function='readFile';

	$self->errorBlank;

	#return false if the config is not set
	if (!defined($args{config})){
		$self->{error}=25;
		$self->{errorString}='$config not defined';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;			
	}

	#return false if the config is not set
	if (!defined($args{set})){
		$self->{error}=24;
		$self->{errorString}='$arg{set} not defined';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;			
	}

	#default to overriding
	if (!defined($args{override})) {
		$args{override}=1;
	}

	my $fullpath=$self->{args}{base}."/".$args{config}."/".$args{set};

	#return false if the full path does not exist
	if (!-f $fullpath){
		return 0;
	}

	#retun from a this if a comma is found in it
	if( $args{config} =~ /,/){
		return 0;
	}

	if(!open("thefile", $fullpath)){
		return 0;
	};
	my @rawdataA=<thefile>;
	close("thefile");
	
	my $rawdata=join('', @rawdataA);
	
	#gets it
	my $zml=ZML->new;

	#parses it
	$zml->parse($rawdata);
	if ($zml->{error}) {
		$self->{error}=28;
		$self->{errorString}='$zml->parse errored. $zml->{error}="'.$zml->{error}.'" '.
		                     '$zml->{errorString}="'.$zml->{errorString}.'"';
		warn($self->{module}.' '.$function.':'.$self->{errror}.': '.$self->{errorString});
		return undef;
	}

	#at this point we save the stuff in it
	$self->{conf}{$args{config}}=\%{$zml->{var}};
	$self->{meta}{$args{config}}=\%{$zml->{meta}};
	$self->{comment}{$args{config}}=\%{$zml->{comment}};

	#sets the set that was read		
	$self->{set}{$args{config}}=$args{set};

	#updates the revision
	my $revisionfile=$self->{args}{base}."/".$args{config}."/.revision";
	#opens the file and returns if it can not
	#creates it if necesary
	if ( -f $revisionfile) {
		if(!open("THEREVISION", '<', $revisionfile)){
			warn($self->{module}.' '.$function.':43: '."'".$revisionfile."' open failed");
			$self->{revision}{$args{config}}=time.' '.hostname.' '.rand();
		}
		$self->{revision}{$args{config}}=join('', <THEREVISION>);
		close(THEREVISION);
	}else {
		$self->{revision}{$args{config}}=time.' '.hostname.' '.rand();
		#tag it with a revision if it does not have any...
		if(!open("THEREVISION", '>', $revisionfile)){
			$self->{error}=43;
			$self->{errorString}="'".$revisionfile."' open failed";
			warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
			return undef;
		}
		print THEREVISION $self->{revision}{$args{config}};
		close("THEREVISION");
	}

	#checks if it is locked or not and save it
	my $locked=$self->isConfigLockedFile($args{config});
	if ($locked) {
		$self->{locked}{$args{config}}=1;
	}

	#run the overrides if requested tox
	if ($args{override}) {
		#runs the override if not locked
		if (!$locked) {
			$self->override({ config=>$args{config} });
		}
	}

	return $self->{revision}{$args{config}};
}

=head2 readLDAP

readFile functions just like read, but is mainly intended for internal use
only. This reads the config from the LDAP backend.

=head3 hash args

=head4 config

The config to load.

=head4 override

This specifies if override should be ran not.

If this is not specified, it defaults to 1, true.

=head4 set

The set for that config to load.

    $zconf->readLDAP({config=>"foo/bar"})
	if($zconf->{error}){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	}

=cut

#read a config from a file
sub readLDAP{
	my $self=$_[0];
	my %args=%{$_[1]};
	my $function='readLDAP';

	$self->errorBlank;

	#return false if the config is not set
	if (!defined($args{config})){
		$self->{error}=25;
		$self->{errorString}='$config not defined';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;			
	}

	#return false if the config is not set
	if (!defined($args{set})){
		$self->{error}=24;
		$self->{errorString}='$arg{set} not defined';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;			
	}

	#default to overriding
	if (!defined($args{override})) {
		$args{override}=1;
	}

	#creates the DN from the config
	my $dn=$self->config2dn($args{config}).",".$self->{args}{"ldap/base"};

	#gets the LDAP entry
	my $entry=$self->LDAPgetConfEntry($args{config});
	#return upon error
	if (defined($self->{error})) {
		warn($self->{module}.' '.$function.': LDAPgetConfEntry errored');
		return undef;
	}

	if(!defined($entry->dn())){
		$self->{error}=13;
		$self->{errorString}="Expected DN, '".$dn."' not found.";
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}else{
		if($entry->dn ne $dn){
			$self->{error}=13;
			$self->{errorString}="Expected DN, '".$dn."' not found.";
			warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
			return undef;			
		}
	}

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
		}
	}else{
		#If we end up here, it means it is a bad LDAP enty
		$self->{error}=13;
		$self->{errorString}="No zconfData entry found in '".$dn."'.";
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;	
	}

	#error out if $data is undefined
	if(!defined($data)){
		$self->{error}=13;
		$self->{errorString}="No matching sets found in '".$args{config}."'.";
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;	
	}
	
		
	#removes the firstline from the data
	$data=~s/^$args{set}\n//;
	
	#parse the ZML stuff
	my $zml=ZML->new();
	$zml->parse($data);
	if ($zml->{error}) {
		$self->{error}=28;
		$self->{errorString}='$zml->parse errored. $zml->{error}="'.$zml->{error}.'" '.
		                     '$zml->{errorString}="'.$zml->{errorString}.'"';
		warn($self->{module}.' '.$function.':'.$self->{errror}.': '.$self->{errorString});
		return undef;
	}
	$self->{conf}{$args{config}}=\%{$zml->{var}};
	$self->{meta}{$args{config}}=\%{$zml->{meta}};
	$self->{comment}{$args{config}}=\%{$zml->{comment}};

	#sets the loaded config
	$self->{set}{$args{config}}=$args{set};

	#gets the revisions
	my @revs=$entry->get_value('zconfRev');
	if (!defined($revs[0])) {
		my $revision=time.' '.hostname.' '.rand();
		$self->{revision}{$args{config}}=$revision;
		$entry->add(zconfRev=>[$revision]);

		#connects to LDAP
		my $ldap=$self->LDAPconnect();
		if (defined($self->{error})) {
			warn($self->{module}.' '.$function.': LDAPconnect failed for the purpose of updating');
			return $self->{revision}{$args{config}};
		}

		$entry->update($ldap);
	}else {
		$self->{revision}{$args{config}}=$revs[0];
	}

	#checks if it is locked or not and save it
	my $locked=$self->isConfigLockedLDAP($args{config});
	if ($locked) {
		$self->{locked}{$args{config}}=1;
	}

	#run the overrides if requested tox
	if ($args{override}) {
		#runs the override if not locked
		if (!$locked) {
			$self->override({ config=>$args{config} });
		}
	}

	return $self->{revision}{$args{config}};
}

=head2 readChooser

This reads the chooser for a config. If no chooser is defined "" is returned.

The name of the config is the only required arguement.

	my $chooser = $zconf->readChooser("foo/bar")
	if($zconf->{error}){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	}

=cut

#the overarching readChooser
#this gets the chooser for a the config
sub readChooser{
	my ($self, $config)= @_;
	my $function='readChooser';

	$self->errorBlank;

	#return false if the config is not set
	if (!defined($config)){
		$self->{error}=25;
		$self->{errorString}='$config not defined';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;			
	}

	#make sure the config name is legit
	my ($error, $errorString)=$self->configNameCheck($config);
	if(defined($error)){
		$self->{error}=$error;
		$self->{errorString}=$errorString;
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#checks to make sure the config does exist
	if(!$self->configExists($config)){
		warn("zconf readChooser:12: '".$config."' does not exist.");
		$self->{error}=12;
		$self->{errorString}="'".$config."' does not exist.";
		return undef;			
	}
		
	my $returned=undef;

	#reads the chooser
	if($self->{args}{backend} eq "file"){
		$returned=$self->readChooserFile($config);
	}else{
		if($self->{args}{backend} eq "ldap"){
			$returned=$self->readChooserLDAP($config);
		}
		#if it errors and read fall through is turned on, try the file backend
		if ($self->{error}&&$self->{args}{readfallthrough}) {
			$self->errorBlank;
			$returned=$self->readChooserFile($config);
			#we return here because if we don't we will pointlessly sync it
			return $returned;
		}
	}

	if($self->{error}){
		return undef;
	}

	#attempt to sync the chooser locally if not using the file backend
	if($self->{args}{backend} ne "file"){
		my $syncReturn;
		if (!$self->configExistsFile($config)) {
			$syncReturn=$self->createConfigFile($config);
			if (!$syncReturn){
				warn($self->{module}.' '.$function.': sync failed');
			}
		}
		$syncReturn=$self->writeChooserFile($config, $returned);
		if (!$syncReturn){
			warn($self->{module}.' '.$function.': sync failed');
		}
	}

	return $returned;
}

=head2 readChooserFile




This functions just like readChooser, but functions on the file backend
and only really intended for internal use.

	my $chooser = $zconf->readChooserFile("foo/bar");
	if($zconf->{error}){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	}

=cut

#this gets the chooser for a the config... for the file backend
sub readChooserFile{
	my ($self, $config)= @_;
	my $function='readChooserFile';

	$self->errorBlank;

	#return false if the config is not set
	if (!defined($config)){
		$self->{error}=25;
		$self->{errorString}='$config not defined';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;			
	}

	#make sure the config name is legit
	my ($error, $errorString)=$self->configNameCheck($config);
	if(defined($error)){
		$self->{error}=$error;
		$self->{errorString}=$errorString;
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}
		
	#checks to make sure the config does exist
	if(!$self->configExists($config)){
		$self->{error}=12;
		$self->{errorString}="'".$config."' does not exist.";
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;			
	}

	#the path to the file
	my $chooser=$self->{args}{base}."/".$config."/.chooser";

	#if the chooser does not exist, turn true, but blank 
	if(!-f $chooser){
		return "";
	}

	#open the file and get the string error on not being able to open it 
	if(!open("READCHOOSER", $chooser)){
		$self->{error}=15;
		$self->{errorString}="'".$self->{args}{base}."/".$config."/.chooser' read failed.";
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}
	my $chooserstring=<READCHOOSER>;
	close("READCHOOSER");		

	return ($chooserstring);
}

=head2 readChooserLDAP

This functions just like readChooser, but functions on the LDAP backend
and only really intended for internal use.

	my $chooser = $zconf->readChooserLDAP("foo/bar");
	if($zconf->{error}){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	}

=cut

#this gets the chooser for a the config... for the file backend
sub readChooserLDAP{
	my ($self, $config)= @_;
	my $function='readChooserLDAP';

	$self->errorBlank;

	#return false if the config is not set
	if (!defined($config)) {
		$self->{error}=25;
		$self->{errorString}='$config not defined';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;			
	}

	#make sure the config name is legit
	my ($error, $errorString)=$self->configNameCheck($config);
	if (defined($error)) {
		$self->{error}=$error;
		$self->{errorString}=$errorString;
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#checks to make sure the config does exist
	if (!$self->configExists($config)) {
		$self->{error}=12;
		$self->{errorString}="'".$config."' does not exist.";
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;			
	}

	#creates the DN from the config
	my $dn=$self->config2dn($config).",".$self->{args}{"ldap/base"};

	#gets the LDAP mesg
	my $ldapmesg=$self->LDAPgetConfMessage($config);
	#return upon error
	if (defined($self->{error})) {
		return undef;
	}

	my %hashedmesg=LDAPhash($ldapmesg);
	if (!defined($hashedmesg{$dn})) {
		$self->{error}=13;
		$self->{errorString}="Expected DN, '".$dn."' not found.";
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	if (defined($hashedmesg{$dn}{ldap}{zconfChooser}[0])) {
		return($hashedmesg{$dn}{ldap}{zconfChooser}[0]);
	} else {
		return("");
	}
}

=head2 regexCommentDel

This searches through the comments for variables in a loaded config for
any that match the supplied regex and removes them.

One arguement is taken and it is a hash.

A hash of hash containing copies of the deleted variables are returned.

=head3 args hash

=head4 config

This is the config search.

=head4 varRegex

The variable to search for matching comment names.

=head4 commentRegex

The regex use for matching comment names.

    my %deleted=$zconf->regexCommentDel({
                                         config=>"foo/bar",
                                         varRegex=>"^some/var$",
                                         commentRegex=>"^monkey\/";
                                        });
	if($zconf->{error}){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	}

=cut

#removes variables based on a regex
sub regexCommentDel{
	my $self=$_[0];
	my %args;
	if (defined($_[1])) {
		%args=%{$_[1]};
	}
	my $function='regexCommentDel';

	$self->errorBlank;

	#update if if needed
	$self->updateIfNeeded({config=>$args{config}, clearerror=>1, autocheck=>1 });

	#return false if the config is not set
	if (!defined($args{config})){
		$self->{error}=25;
		$self->{errorString}='$config not defined';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;			
	}

	#return false if the config is not set
	if (!defined($args{varRegex})){
		$self->{error}=18;
		$self->{errorString}='$args{varRegex} not defined';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#make sure the loaded config is not locked
	if (defined($self->{locked}{$args{config}})) {
		$self->{error}=45;
		$self->{errorString}='The config "'.$args{config}.'" is locked';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	my @vars=keys(%{$self->{comment}{$args{config}}});

	my %returned;

	#run through checking it all
	my $varsInt=0;
	while(defined($vars[$varsInt])){
		#if the variable matches, it is ok
		if ($vars[$varsInt] =~ /$args{varRegex}/) {
			my @comments=keys(%{$self->{comment}{ $args{config} }{ $vars[$varsInt] }});
			my $commentsInt=0;
			#check the each meta
			while (defined($comments[$commentsInt])) {
				#remove any matches
				if ($self->{comment}{ $args{config} }{ $vars[$varsInt] }{ $comments[$commentsInt] } =~ /$args{commentRegex}/) {
					#copies the variable before it is deleted
					if (!defined( $returned{ $vars[$varsInt] } )) {
						$returned{ $vars[$varsInt] }={};
					}
					$returned{ $vars[$varsInt] }{ $comments[$commentsInt] }=
					                            $self->{comment}{ $args{config} }{ $vars[$varsInt] }{ $comments[$commentsInt] };
					delete($self->{comment}{ $args{config} }{ $vars[$varsInt] }{ $comments[$commentsInt] });
				}
				
				$commentsInt++;
			}
		}

		$varsInt++;
	}

	return %returned;
}

=head2 regexCommentGet

This searches through the comments for variables in a loaded config for
any that match the supplied regex and returns them.

One arguement is taken and it is a hash.

A hash of hash containing copies of the deleted variables are returned.

=head3 args hash

=head4 config

This is the config search.

=head4 varRegex

The variable to search for matching comment names.

=head4 commentRegex

The regex use for matching comment names.

    my %deleted=$zconf->regexCommentGet({
                                         config=>"foo/bar",
                                         varRegex=>"^some/var$",
                                         commentRegex=>"^monkey\/";
                                        });
	if($zconf->{error}){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	}

=cut

#removes variables based on a regex
sub regexCommentGet{
	my $self=$_[0];
	my %args;
	if (defined($_[1])) {
		%args=%{$_[1]};
	}
	my $function='regexCommentGet';

	$self->errorBlank;

	#update if if needed
	$self->updateIfNeeded({config=>$args{config}, clearerror=>1, autocheck=>1 });

	#return false if the config is not set
	if (!defined($args{config})) {
		$self->{error}=25;
		$self->{errorString}='$config not defined';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;			
	}

	#return false if the config is not set
	if (!defined($args{varRegex})) {
		$self->{error}=18;
		$self->{errorString}='$args{varRegex} not defined';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;			
	}

	my @vars=keys(%{$self->{comment}{$args{config}}});

	my %returned;

	#run through checking it all
	my $varsInt=0;
	while (defined($vars[$varsInt])) {
		#if the variable matches, it is ok
		if ($vars[$varsInt] =~ /$args{varRegex}/) {
			my @comments=keys(%{$self->{comment}{ $args{config} }{ $vars[$varsInt] }});
			my $commentsInt=0;
			#check the each meta
			while (defined($comments[$commentsInt])) {
				#remove any matches
				if ($self->{comment}{ $args{config} }{ $vars[$varsInt] }{ $comments[$commentsInt] } =~ /$args{commentRegex}/) {
					#adds it to the returned hash
					if (!defined( $returned{ $vars[$varsInt] } )) {
						$returned{ $vars[$varsInt] }={};
					}
					$returned{ $vars[$varsInt] }{ $comments[$commentsInt] }=
					$self->{comment}{ $args{config} }{ $vars[$varsInt] }{ $comments[$commentsInt] };
				}
				
				$commentsInt++;
			}
		}

		$varsInt++;
	}

	return %returned;
}

=head2 regexMetaDel

This searches through the meta variables in a loaded config for any that match
the supplied regex and removes them.

One arguement is taken and it is a hash.

A hash of hash containing copies of the deleted variables are returned.

=head3 args hash

=head4 config

This is the config search.

=head4 varRegex

The variable to search for matching comment names.

=head4 metaRegex

The regex use for matching meta variables.

    my %deleted=$zconf->regexMetaDel({
                                      config=>"foo/bar",
                                      varRegex=>"^some/var$",
                                      metaRegex=>"^monkey\/";
                                     });
	if($zconf->{error}){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	}

=cut

#removes variables based on a regex
sub regexMetaDel{
	my $self=$_[0];
	my %args;
	if (defined($_[1])) {
		%args=%{$_[1]};
	}
	my $function='regexMetaDel';

	$self->errorBlank;

	#update if if needed
	$self->updateIfNeeded({config=>$args{config}, clearerror=>1, autocheck=>1 });

	#return false if the config is not set
	if (!defined($args{config})){
		$self->{error}=25;
		$self->{errorString}='$config not defined';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;			
	}

	#return false if the config is not set
	if (!defined($args{varRegex})){
		$self->{error}=18;
		$self->{errorString}='$args{varRegex} not defined';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;			
	}

	#make sure the loaded config is not locked
	if (defined($self->{locked}{$args{config}})) {
		$self->{error}=45;
		$self->{errorString}='The config "'.$args{config}.'" is locked';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	my @vars=keys(%{$self->{meta}{$args{config}}});

	my %returned;

	#run through checking it all
	my $varsInt=0;
	while(defined($vars[$varsInt])){
		#if the variable matches, it is ok
		if ($vars[$varsInt] =~ /$args{varRegex}/) {
			my @metas=keys(%{$self->{meta}{ $args{config} }{ $vars[$varsInt] }});
			my $metasInt=0;
			#check the each meta
			while (defined($metas[$metasInt])) {
				#remove any matches
				if ($self->{meta}{ $args{config} }{ $vars[$varsInt] }{ $metas[$metasInt] } =~ /$args{metaRegex}/) {
					#copies the variable before it is deleted
					if (!defined( $returned{ $vars[$varsInt] } )) {
						$returned{ $vars[$varsInt] }={};
					}
					$returned{ $vars[$varsInt] }{ $metas[$metasInt] }=
					                            $self->{meta}{ $args{config} }{ $vars[$varsInt] }{ $metas[$metasInt] };
					delete($self->{meta}{ $args{config} }{ $vars[$varsInt] }{ $metas[$metasInt] });
				}
				
				$metasInt++;
			}
		}

		$varsInt++;
	}

	return %returned;
}

=head2 regexMetaGet

This searches through the meta variables in a loaded config for any that match
the supplied regex and removes them.

One arguement is taken and it is a hash.

A hash of hash containing copies of the deleted variables are returned.

=head3 args hash

=head4 config

This is the config search.

=head4 varRegex

The variable to search for matching comment names.

=head4 metaRegex

The regex use for matching meta variables.

    my %deleted=$zconf->regexMetaGet({
                                      config=>"foo/bar",
                                      varRegex=>"^some/var$",
                                      metaRegex=>"^monkey\/";
                                     });
	if($zconf->{error}){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	}

=cut

#removes variables based on a regex
sub regexMetaGet{
	my $self=$_[0];
	my %args;
	if (defined($_[1])) {
		%args=%{$_[1]};
	}
	my $function='regexMetaGet';

	$self->errorBlank;

	#update if if needed
	$self->updateIfNeeded({config=>$args{config}, clearerror=>1, autocheck=>1 });

	#return false if the config is not set
	if (!defined($args{config})){
		$self->{error}=25;
		$self->{errorString}='$config not defined';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;			
	}

	#return false if the config is not set
	if (!defined($args{varRegex})){
		$self->{error}=18;
		$self->{errorString}='$args{varRegex} not defined';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;			
	}

	my @vars=keys(%{$self->{meta}{$args{config}}});

	my %returned;

	#run through checking it all
	my $varsInt=0;
	while(defined($vars[$varsInt])){
		#if the variable matches, it is ok
		if ($vars[$varsInt] =~ /$args{varRegex}/) {
			my @metas=keys(%{$self->{meta}{ $args{config} }{ $vars[$varsInt] }});
			my $metasInt=0;
			#check the each meta
			while (defined($metas[$metasInt])) {
				#add any matched
				if ($self->{meta}{ $args{config} }{ $vars[$varsInt] }{ $metas[$metasInt] } =~ /$args{metaRegex}/) {
					#copies the variable before it is deleted
					if (!defined( $returned{ $vars[$varsInt] } )) {
						$returned{ $vars[$varsInt] }={};
					}
					$returned{ $vars[$varsInt] }{ $metas[$metasInt] }=
					                            $self->{meta}{ $args{config} }{ $vars[$varsInt] }{ $metas[$metasInt] };
				}
				
				$metasInt++;
			}
		}

		$varsInt++;
	}

	return %returned;
}

=head2 regexVarDel

This searches through the variables in a loaded config for any that match
the supplied regex and removes them.

Two arguements are required. The first is the config to search. The second
is the regular expression to use.

	#removes any variable starting with the monkey
	my @deleted = $zconf->regexVarDel("foo/bar", "^monkey");
	if($zconf->{error}){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	}

=cut

#removes variables based on a regex
sub regexVarDel{
	my ($self, $config, $regex) = @_;
	my $function='regexVarDel';

	$self->errorBlank;

	#update if if needed
	$self->updateIfNeeded({config=>$config, clearerror=>1, autocheck=>1 });

	#return false if the config is not set
	if (!defined($config)){
		$self->{error}=25;
		$self->{errorString}='$config not defined';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;			
	}

	if(!defined($self->{conf}{$config})){
		$self->{error}=26;
		$self->{errorString}="Config '".$config."' is not loaded.";
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#make sure the loaded config is not locked
	if (defined($self->{locked}{$config})) {
		$self->{error}=45;
		$self->{errorString}='The config "'.$config.'" is locked';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	my @keys=keys(%{$self->{conf}{$config}});

	my @returnKeys=();

	my $int=0;
	while(defined($keys[$int])){
		if($keys[$int] =~ /$regex/){
			delete($self->{conf}{$config}{$keys[$int]});
			push(@returnKeys, $keys[$int]);
		}

		$int++;
	}

	return @returnKeys;				
}

=head2 regexVarGet

This searches through the variables in a loaded config for any that match
the supplied regex and returns them in a hash.

Two arguements are required. The first is the config to search. The second
is the regular expression to use.

	#returns any variable begining with monkey
	my %vars = $zconf->regexVarGet("foo/bar", "^monkey");
	if($zconf->{error}){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	}

=cut

#returns a hash of regex matched vars
#return undef on error	
sub regexVarGet{
	my ($self, $config, $regex) = @_;
	my $function='regexVarGet';

	$self->errorBlank;

	#update if if needed
	$self->updateIfNeeded({config=>$config, clearerror=>1, autocheck=>1 });

	#return false if the config is not set
	if (!defined($config)){
		$self->{error}=25;
		$self->{errorString}='$config not defined';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;			
	}

	if(!defined($self->{conf}{$config})){
		$self->{error}=25;
		$self->{errorString}="Config '".$config."' is not loaded.";
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	my @keys=keys(%{$self->{conf}{$config}});

	my %returnKeys=();

	my $int=0;
	while(defined($keys[$int])){
		if($keys[$int] =~ /$regex/){
			$returnKeys{$keys[$int]}=$self->{conf}{$config}{$keys[$int]};
		}
			
		$int++;
	}

	return %returnKeys;
}

=head2 regexVarSearch

This searches through the variables in a loaded config for any that match
the supplied regex and returns a array of matches.

Two arguements are required. The first is the config to search. The second
is the regular expression to use.

	#removes any variable starting with the monkey
	my @matched = $zconf->regexVarSearch("foo/bar", "^monkey")
	if($zconf->{error})){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	}

=cut

#search variables based on a regex	
sub regexVarSearch{
	my ($self, $config, $regex) = @_;
	my $function='regexVarSearch';

	$self->errorBlank;

	#update if if needed
	$self->updateIfNeeded({config=>$config, clearerror=>1, autocheck=>1 });

	#return false if the config is not set
	if (!defined($config)){
		$self->{error}=25;
		$self->{errorString}='$config not defined';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;			
	}

	if(!defined($self->{conf}{$config})){
		$self->{error}=26;
		$self->{errorString}="Config '".$config."' is not loaded";
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	my @keys=keys(%{$self->{conf}{$config}});

	my @returnKeys=();

	my $int=0;
	while(defined($keys[$int])){
		if($keys[$int] =~ /$regex/){
			push(@returnKeys, $keys[$int]);
		}
			
		$int++;
	}

	return @returnKeys;
}

=head2 reread

This rereads the specified config file. This requires it to be already
loaded.

    $zconf->reread('some/config');
    if($zconf->{error}){
        print "Error!\n";
    }

=cut

sub reread{
	my $self=$_[0];
	my $config=$_[1];
	my $function='reread';

	$self->errorBlank;

	#return false if the config is not set
	if (!defined($config)){
		$self->{error}=25;
		$self->{errorString}='$config not defined';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;			
	}

	if(!defined($self->{set}{$config})){
		$self->{error}=26;
		$self->{errorString}="Set '".$config."' is not loaded.";
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#gets the set
	my $set=$self->getSet($config);
	if ($self->{error}) {
		warn($self->{module}.' '.$function.': getSet errored');
		return undef;
	}

	#reread it
	$self->read({config=>$config, set=>$set});
	if ($self->{error}) {
		warn($self->{module}.' '.$function.': read errored');
		return undef;
	}
	return 1;
}

=head2 setAutoupdate

This sets if a value for autoupdate.

It takes two optional arguements. The first is a
name for a config and second is a boolean value.

If a config name is not specified, it sets the
global value for it.

    #set the global auto update value to false
    $zconf->setAutoupdate(undef, '0');

    #sets it to true for 'some/config'
    $zconf->setAutoupdate('some/config', '1');

=cut

sub setAutoupdate{
	my $self=$_[0];
	my $config=$_[1];
	my $autoupdate=$_[2];

	$self->errorBlank;

	if (!defined( $config )) {
		$self->{autoupdateGlobal}=$autoupdate;
	}

	$self->{autoupdate}{$config}=$autoupdate;

	return 1;
}

=head2 setComment

This sets a comment variable in a loaded config.

Four arguements are required. The first is the name of the config.
The second is the name of the variable. The third is the comment
variable. The fourth is the value.

	$zconf->setComment("foo/bar" , "somethingVar", "someComment", "eat more weazel\n\nor something"
	if($zconf->{error}){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	}


=cut

#sets a comment
sub setComment{
	my ($self, $config, $var, $comment, $value) = @_;
	my $function='setComment';

	#blank the any previous errors
	$self->errorBlank;

	#update if if needed
	$self->updateIfNeeded({config=>$config, clearerror=>1, autocheck=>1 });

	#return false if the config is not set
	if (!defined($config)){
		$self->{error}=25;
		$self->{errorString}='$config not defined';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;			
	}

	#make sure the loaded config is not locked
	if (defined($self->{locked}{$config})) {
		$self->{error}=45;
		$self->{errorString}='The config "'.$config.'" is locked';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#return false if the config is not set
	if (!defined($comment)){
		$self->{error}=41;
		$self->{errorString}='No comment name defined';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;			
	}

	#make sure the config name is legit
	my ($error, $errorString)=$self->configNameCheck($config);
	if(defined($error)){
		$self->{error}=$error;
		$self->{errorString}=$errorString;
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#make sure the config name is legit
	($error, $errorString)=$self->varNameCheck($var);
	if(defined($error)){
		$self->{error}=$error;
		$self->{errorString}=$errorString;
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#make sure the config name is legit
	($error, $errorString)=$self->varNameCheck($comment);
	if(defined($error)){
		$self->{error}=$error;
		$self->{errorString}=$errorString;
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	if(!defined($self->{comment}{$config})){
		$self->{error}=26;
		$self->{errorString}="Config '".$config."' is not loaded.";
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	if(!defined($self->{comment}{$config}{$var})){
		$self->{comment}{$config}{$var}={};
	}

	$self->{comment}{$config}{$var}{$comment}=$value;

	return 1;
}

=head2 setDefault

This sets the default set to use if one is not specified or choosen.

	my $returned = $zconf->setDefault("something")
	if($zconf->{error}){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	}

=cut
	
#sets the default set
sub setDefault{
	my ($self, $set)= @_;
	my $function='setDefault';

	#blank any errors
	$self->errorBlank;

	if($self->setNameLegit($set)){
		$self->{args}{default}=$set;
	}else{
		$self->{error}=27;
		$self->{errorString}="'".$set."' is not a legit set name.";
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef
	}

	return 1;
}

=head2 setExists

This checks if the specified set exists.

Two arguements are required. The first arguement is the name of the config.
The second arguement is the name of the set. If no set is specified, the default
set is used. This is done by calling 'defaultSetExists'.

    my $return=$zconf->setExists("foo/bar", "fubar");
    if($zconf->{error}){
        print "Error!\n";
    }else{
        if($return){
            print "It exists.\n";
        }
    }

=cut

sub setExists{
	my ($self, $config, $set)= @_;
	my $function='setExists';

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

=head2 setLockConfig

This unlocks or logs a config.

Two arguements are taken. The first is a
the config name, required, and the second is
if it should be locked or unlocked

    #lock 'some/config'
    $zconf->setLockConfig('some/config', 1);
    if($zconf->{error}){
        print "Error!\n";
    }

    #unlock 'some/config'
    $zconf->setLockConfig('some/config', 0);
    if($zconf->{error}){
        print "Error!\n";
    }

    #unlock 'some/config'
    $zconf->setLockConfig('some/config');
    if($zconf->{error}){
        print "Error!\n";
    }

=cut

sub setLockConfig{
	my $self=$_[0];
	my $config=$_[1];
	my $lock=$_[2];
	my $function='setLockConfig';

	$self->errorBlank;

	#return false if the config is not set
	if (!defined($config)){
		$self->{error}=25;
		$self->{errorString}='No config specified';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#makes sure it exists
	my $exists=$self->configExists($config);
    if ($self->{error}) {
		warn($self->{module}.' '.$function.': configExists errored');
		return undef;
	}
	if (!$exists) {
		$self->{error}=12;
		$self->{errorString}='The config, "'.$config.'", does not exist';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	my $returned=undef;

	#locks the config
	if($self->{args}{backend} eq "file"){
		$returned=$self->lockConfigFile($config, $lock);
	}else{
		if($self->{args}{backend} eq "ldap"){
			$returned=$self->lockConfigLDAP($config, $lock);
		}

		#sync it
		$self->setLockConfigFile($config, $lock);
	}
	
	return $returned;
}

=head2 setLockConfigFile

This unlocks or logs a config for the file backend.

Two arguements are taken. The first is a
the config name, required, and the second is
if it should be locked or unlocked

    #lock 'some/config'
    $zconf->setLockConfigFile('some/config', 1);
    if($zconf->{error}){
        print "Error!\n";
    }

    #unlock 'some/config'
    $zconf->setLockConfigFile('some/config', 0);
    if($zconf->{error}){
        print "Error!\n";
    }

    #unlock 'some/config'
    $zconf->setLockConfigFile('some/config');
    if($zconf->{error}){
        print "Error!\n";
    }

=cut

sub setLockConfigFile{
	my $self=$_[0];
	my $config=$_[1];
	my $lock=$_[2];
	my $function='setLockConfigFile';

	$self->errorBlank;

	#return false if the config is not set
	if (!defined($config)){
		$self->{error}=25;
		$self->{errorString}='No config specified';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#makes sure it exists
	my $exists=$self->configExists($config);
    if ($self->{error}) {
		warn($self->{module}.' '.$function.': configExists errored');
		return undef;
	}
	if (!$exists) {
		$self->{error}=12;
		$self->{errorString}='The config, "'.$config.'", does not exist';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#locks the config
	my $lockfile=$self->{args}{base}."/".$config."/.lock";

	#handles locking it
	if ($lock) {
		if(!open("THELOCK", '>', $lockfile)){
			$self->{error}=44;
			$self->{errorString}="'".$lockfile."' open failed";
			warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
			return undef;
        }
        print THELOCK time."\n".hostname;
        close("THELOCK");
		#return now that it is locked
		return 1;
	}

	#handles unlocking it
	if (!unlink($lockfile)) {
		$self->{error}=44;
		$self->{errorString}='"'.$lockfile.'" could not be unlinked.';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	return 1;
}

=head2 setLockConfigLDAP

This unlocks or logs a config for the LDAP backend.

Two arguements are taken. The first is a
the config name, required, and the second is
if it should be locked or unlocked

    #lock 'some/config'
    $zconf->setLockConfigLDAP('some/config', 1);
    if($zconf->{error}){
        print "Error!\n";
    }

    #unlock 'some/config'
    $zconf->setLockConfigLDAP('some/config', 0);
    if($zconf->{error}){
        print "Error!\n";
    }

    #unlock 'some/config'
    $zconf->setLockConfigLDAP('some/config');
    if($zconf->{error}){
        print "Error!\n";
    }

=cut

sub setLockConfigLDAP{
	my $self=$_[0];
	my $config=$_[1];
	my $lock=$_[2];
	my $function='setLockConfigLDAP';

	$self->errorBlank;

	#return false if the config is not set
	if (!defined($config)){
		$self->{error}=25;
		$self->{errorString}='No config specified';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#makes sure it exists
	my $exists=$self->configExistsLDAP($config);
    if ($self->{error}) {
		warn($self->{module}.' '.$function.': configExists errored');
		return undef;
	}
	if (!$exists) {
		$self->{error}=12;
		$self->{errorString}='The config, "'.$config.'", does not exist';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	my $entry=$self->LDAPgetConfEntry($config);
	#return upon error
	if ($self->{error}) {
		warn($self->{module}.' '.$function.': LDAPgetConfEntry errored');
		return undef;
	}

	#adds a lock
	if ($lock) {
		$entry->add(zconfLock=>[time."\n".hostname]);
	}

	#removes a lock
	if (!$lock) {
		$entry->delete('zconfLock');
	}
	
	#connects to LDAP
	my $ldap=$self->LDAPconnect();
	if ($self->{error}) {
		warn($self->{module}.' '.$function.': LDAPconnect errored... returning...');
		return undef;
	}

	$entry->update($ldap);

	return 1;
}

=head2 setMeta

This sets a meta variable in a loaded config.

Four arguements are required. The first is the name of the config.
The second is the name of the variable. The third is the meta
variable. The fourth is the value.

	$zconf->setMeta("foo/bar" , "somethingVar", "someComment", "eat more weazel\n\nor something"
	if($zconf->{error}){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	};


=cut

#sets a comment
sub setMeta{
	my ($self, $config, $var, $meta, $value) = @_;
	my $function='setMeta';

	#blank the any previous errors
	$self->errorBlank;

	#update if if needed
	$self->updateIfNeeded({config=>$config, clearerror=>1, autocheck=>1 });

	#return false if the config is not set
	if (!defined($config)){
		$self->{error}=25;
		$self->{errorString}='$config not defined';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#make sure the loaded config is not locked
	if (defined($self->{locked}{$config})) {
		$self->{error}=45;
		$self->{errorString}='The config "'.$config.'" is locked';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#return false if the config is not set
	if (!defined($meta)){
		$self->{error}=41;
		$self->{errorString}='No comment name defined';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;			
	}

	#make sure the var name is legit
	my ($error, $errorString)=$self->varNameCheck($var);
	if(defined($error)){
		$self->{error}=$error;
		$self->{errorString}=$errorString;
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#make sure the meta name is legit
	($error, $errorString)=$self->varNameCheck($meta);
	if(defined($error)){
		$self->{error}=$error;
		$self->{errorString}=$errorString;
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	if(!defined($self->{meta}{$config})){
		$self->{error}=26;
		$self->{errorString}="Config '".$config."' is not loaded.";
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	if(!defined($self->{meta}{$config}{$var})){
		$self->{meta}{$config}{$var}={};
	}

	$self->{meta}{$config}{$var}{$meta}=$value;

	return 1;
}


=head2 setNameLegit

This checks if a setname is legit.

There is one required arguement, which is the set name.

The returned value is a perl boolean value.

	my $set="something";
	if(!$zconf->setNameLegit($set)){
		print "'".$set."' is not a legit set name.\n";
	}

=cut

#checks the setnames to make sure they are legit.
sub setNameLegit{
	my ($self, $set)= @_;

	$self->errorBlank;

	if (!defined($set)){
		return undef;
	}

	#return false if it / is found
	if ($set =~ /\//){
		return undef;
	}
		
	#return undef if it begins with .
	if ($set =~ /^\./){
		return undef;
	}

	#return undef if it begins with " "
	if ($set =~ /^ /){
		return undef;
	}

	#return undef if it ends with " "
	if ($set =~ / $/){
		return undef;
	}

	#return undef if it contains ".."
	if ($set =~ /\.\./){
		return undef;
	}

	return 1;
}

=head2 setOverrideChooser

This will get the current override chooser for a config.

If no chooser is specified for the loaded config

Two arguements are required. The first is the config
and th e second is the chooser string.

This method is basically a wrapper around setMeta.

    $zconf->setOverrideChooser($config, $chooser);
    if($zconf->{error}){
        print "Error!\n";
    }

=cut

sub setOverrideChooser{
	my $self=$_[0];
	my $config=$_[1];
	my $chooser=$_[2];
	my $function='getOverrideChooser';

	#blank the any previous errors
	$self->errorBlank;

	#return false if the config is not set
	if (!defined($config)){
		$self->{error}=25;
		$self->{errorString}='$config not defined';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;			
	}

	#make sure the loaded config is not locked
	if (defined( $self->{locked}{ $config } )) {
		$self->{error}=45;
		$self->{errorString}='The config "'.$config.'" is locked';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#return false if the config is not set
	if (!defined($chooser)){
		$self->{error}=40;
		$self->{errorString}='$chooser not defined';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;			
	}

	#make sure the loaded config is not locked
	if (defined( $self->{locked}{ $config } )) {
		$self->{error}=45;
		$self->{errorString}='The config "'.$config.'" is locked';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	if (!defined( $self->{meta}{$config}{zconf} )){
		$self->{meta}{$config}{zconf}={};
	}

	$self->{meta}{$config}{zconf}{'override/chooser'}=$chooser;

	return 1;
}

=head2 setVar

This sets a variable in a loaded config.

Three arguements are required. The first is the name of the config.
The second is the name of the variable. The third is the value.

	$zconf->setVar("foo/bar" , "something", "eat more weazel\n\nor something"
	if($zconf->{error}){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	}


=cut

#sets a variable
sub setVar{
	my ($self, $config, $var, $value) = @_;
	my $function='setVar';

	#blank the any previous errors
	$self->errorBlank;

	#update if if needed
	$self->updateIfNeeded({config=>$config, clearerror=>1, autocheck=>1});

	#return false if the config is not set
	if (!defined($config)){
		$self->{error}=25;
		$self->{errorString}='$config not defined';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;			
	}

	#make sure the loaded config is not locked
	if (defined($self->{locked}{$config})) {
		$self->{error}=45;
		$self->{errorString}='The config "'.$config.'" is locked';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#make sure the config name is legit
	my ($error, $errorString)=$self->varNameCheck($var);
	if(defined($error)){
		$self->{error}=$error;
		$self->{errorString}=$errorString;
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	if(!defined($self->{conf}{$config})){
		$self->{error}=26;
		$self->{errorString}="Config '".$config."' is not loaded.";
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	if(!defined($var)){
		$self->{error}=18;
		$self->{errorString}="\$var is not defined.";
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	$self->{conf}{$config}{$var}=$value;

	#makes sure that the config var for it the meta info exists
	if (!defined( $self->{meta}{$config}{$var} )) {
		$self->{meta}{$config}{$var}={};
	}
	#set the mtime
	$self->{meta}{$config}{$var}{'mtime'}=time;
	#sets the ctime if needed
	if (!defined( $self->{meta}{$config}{$var}{'ctime'} )) {
		$self->{meta}{$config}{$var}{'ctime'}=time;
	}


	return 1;
}

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
	my $function='unloadConfig';

	$self->errorBlank();

	#return false if the config is not set
	if (!defined($config)){
		$self->{error}=25;
		$self->{errorString}='$config not defined';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;			
	}

	if (!defined($self->{conf}{$config})){
		$self->{error}=26;
		$self->{errorString}='The specified config, ".$config.", is not loaded';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		#even if it is not defined, check to see if this is defined and remove it
		if (defined($self->{set}{$config})){
			delete($self->{set}{$config});
		}
		return undef;
	}else {
		delete($self->{conf}{$config});
	}

	#removes the loaded set information
	if (defined($self->{set}{$config})){
		delete($self->{set}{$config});
	}

	#remove any lock info
	if (defined($self->{locked}{$config})) {
		delete($self->{locked}{$config});
	}

	#remove any meta info
	if (defined($self->{meta}{$config})) {
		delete($self->{meta}{$config});
	}

	#remove any comment info
	if (defined($self->{comment}{$config})) {
		delete($self->{comment}{$config});
	}

	#remove any revision info
	if (defined($self->{revision}{$config})) {
		delete($self->{revision}{$config});
	}

	return 1;
}

=head2 updatable

This checks if the loaded config on disk has a different revision ID than the 
saved one.

The return value is a boolean value. A value of true indicates the config has
been changed on the backend.

    my $updatable=$zconf->updatable('some/config');
    if($zconf->{error}){
        print "Error!";
    }

=cut

sub updatable{
	my $self=$_[0];
	my $config=$_[1];
	my $function='updatable';

	$self->errorBlank;

	#return false if the config is not set
	if (!defined($config)){
		$self->{error}=25;
		$self->{errorString}='No config specified';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#make sure it is loaded
	if(!defined($self->{conf}{$config})){
		$self->{error}=26;
		$self->{errorString}="Config '".$config."' is not loaded.";
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	my $backendRev=$self->getConfigRevision($config);
	if ($self->{error}) {
		warn($self->{module}.' '.$function.': getConfigRevision failed');
		return undef;
	}

	#return false as if this is not defined, it means
	#that the config has no sets or has never been read
	#on a version of ZConf newer than 2.0.0
	if (!defined($backendRev)) {
		return undef;
	}

	#if we are here, it will no error so we don't check
	my $loadedRev=$self->getLoadedConfigRevision($config);

	#they are not the same so a update is available
	if ($backendRev ne $loadedRev) {
		return 1;
	}

	#the are the same so no updates
	return undef;
}

=head2 updateIfNeeded

If a loaded config is updatable, reread it.

The returned value is a boolean value indicating
if it was updated or not. A value of true indicates
it was.

=head3 args hash

=head4 autocheck

This tells it to check getAutoupdate. If it returns false,
it will return.

=head4 clearerror

If $zconf->{error} is set, clear it. This is primarily
meant for being used internally.

=head4 config

This config to check.

This is required.

    my $updated=$zconf->updateIfNeeded({config=>'some/config'});
    if($zconf->{error}){
        print "Error!\n";
    }
    if($updated){
        print "Updated!\n";
    }

=cut

sub updateIfNeeded{
	my $self=$_[0];
	my %args;
	if (defined($_[1])) {
		%args=%{$_[1]};
	}
	my $function='updateIfNeeded';

	$self->errorBlank;

	#return false if the config is not set
	if (!defined($args{config})){
		$self->{error}=25;
		$self->{errorString}='No config specified';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#make sure it is loaded
	if(!defined($self->{conf}{ $args{config} })){
		$self->{error}=26;
		$self->{errorString}="Config '".$args{config}."' is not loaded.";
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}	

	#checks the value for autoupdate
	if ($args{autocheck}) {
		my $autoupdate=$self->getAutoupdate($args{config});
		if(!$autoupdate){
			return undef;
		}
	}

	#check if it is updatable
	my $updatable=$self->updatable($args{config});
	if ($self->{error}) {
		warn($self->{module}.' '.$function.': updatable errored');
		return undef;
	}

	#not updatable
	if (!$updatable) {
		return undef;
	}

	#reread it
	$self->reread($args{config});
	if ($self->{error}) {
		warn($self->{module}.' '.$function.': reread errored');
		#clear the error if needed
		if ($args{clearerror}) {
			$self->errorBlank;
		}

		return undef;
	}

	return 1;
}

=head2 varNameCheck

This checks if a there if the specified variable name is a legit one or not.

	my ($error, $errorString) = $zconf->varNameCheck($config);
	if(defined($error)){
        print $error.': '.$errorString."\n";
	}

=cut

sub varNameCheck{
        my ($self, $name) = @_;

		$self->errorBlank;

		#makes sure it is defined
		if (!defined($name)) {
			return('10', 'variable name is not defined');
		}

        #checks for ,
        if($name =~ /,/){
                return("0", "variavble name,'".$name."', contains ','");
        }

        #checks for /.
        if($name =~ /\/\./){
                return("1", "variavble name,'".$name."', contains '/.'");
        }

        #checks for //
        if($name =~ /\/\//){
                return("2", "variavble name,'".$name."', contains '//'");
        }

        #checks for ../
        if($name =~ /\.\.\//){
                return("3", "variavble name,'".$name."', contains '../'");
        }

        #checks for /..
        if($name =~ /\/\.\./){
                return("4", "variavble name,'".$name."', contains '/..'");
        }

        #checks for ^./
        if($name =~ /^\.\//){
                return("5", "variavble name,'".$name."', matched /^\.\//");
        }

        #checks for /$
        if($name =~ /\/$/){
                return("6", "variavble name,'".$name."', matched /\/$/");
        }

        #checks for ^/
        if($name =~ /^\//){
                return("7", "variavble name,'".$name."', matched /^\//");
        }

        #checks for \\n
        if($name =~ /\n/){
                return("8", "variavble name,'".$name."', matched /\\n/");
        }

        #checks for =
        if($name =~ /=/){
                return("9", "variavble name,'".$name."', matched /=/");
        }

		return(undef, "");	
}

=head2 writeChooser

This writes a string into the chooser for a config.

There are two required arguements. The first is the
config name. The second is chooser string.

No error checking is done currently on the chooser string.

Setting this to '' or "\n" will disable the chooser fuction
and the default will be used when chooseSet is called.

	my $returned = $zconf->writeChooser("foo/bar", $chooserString)
	if($zconf->{error}){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	}

=cut

#the overarching read
sub writeChooser{
	my ($self, $config, $chooserstring)= @_;
	my $function='writeChooser';

	$self->errorBlank;

	#return false if the config is not set
	if (!defined($config)){
		$self->{error}=25;
		$self->{errorString}='$config not defined';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;			
	}

	#return false if the config is not set
	if (!defined($chooserstring)){
		$self->{error}=40;
		$self->{errorString}='\$chooserstring not defined';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;			
	}

	#make sure the config name is legit
	my ($error, $errorString)=$self->configNameCheck($config);
	if(defined($error)){
		$self->{error}=$error;
		$self->{errorString}=$errorString;
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}
		
	#checks to make sure the config does exist
	if(!$self->configExists($config)){
		$self->{error}=12;
		$self->{errorString}="'".$config."' does not exist.";
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#checks if it is locked or not
	my $locked=$self->isConfigLocked($config);
	if ($self->{error}) {
		warn($self->{module}.' '.$function.': isconfigLocked errored');
		return undef;
	}
	if ($locked) {
		$self->{error}=45;
		$self->{errorString}='The config "'.$config.'" is locked';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	if(defined($self->{error})){
		return undef;
	}

	my $returned=undef;

	#reads the chooser
	if($self->{args}{backend} eq "file"){
		$returned=$self->writeChooserFile($config, $chooserstring);
	}else{
		if($self->{args}{backend} eq "ldap"){
			$returned=$self->writeChooserLDAP($config, $chooserstring);
		}
	}

	if(!$returned){
		return undef;
	}
		
	#attempt to sync the chooser locally if not using the file backend
	if($self->{args}{backend} ne "file"){
		my $syncReturn;
		if (!$self->configExistsFile($config)) {
			$syncReturn=$self->createConfigFile($config);
			if (!$syncReturn){
				warn($self->{module}.' '.$function.': sync failed');
			}
		}
		$syncReturn=$self->writeChooserFile($config, $chooserstring);
		if (!$syncReturn){
			warn("zconf read error: Could not sync config to the loaded config.");
		}
	}
		
	return 1;
}

=head2 writeChooserFile

This function is a internal function and largely meant to only be called
writeChooser, which it functions the same as. It works on the file backend.

	$zconf->writeChooserFile("foo/bar", $chooserString)
	if($zconf->{error}){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	}

=cut

sub writeChooserFile{
	my ($self, $config, $chooserstring)= @_;
	my $function='writeChooserFile';

	$self->errorBlank;

	#return false if the config is not set
	if (!defined($config)){
		$self->{error}=25;
		$self->{errorString}='$config not defined';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#checks if it is locked or not
	my $locked=$self->isConfigLockedFile($config);
	if ($self->{error}) {
		warn($self->{module}.' '.$function.': isconfigLockedFile errored');
		return undef;
	}
	if ($locked) {
		$self->{error}=45;
		$self->{errorString}='The config "'.$config.'" is locked';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#return false if the config is not set
	if (!defined($chooserstring)){
		$self->{error}=40;
		$self->{errorString}='\$chooserstring not defined';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;			
	}

	#make sure the config name is legit
	my ($error, $errorString)=$self->configNameCheck($config);
	if(defined($error)){
		$self->{error}=$error;
		$self->{errorString}=$errorString;
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	my $chooser=$self->{args}{base}."/".$config."/.chooser";

	#open the file and get the string error on not being able to open it 
	if(!open("WRITECHOOSER", ">", $chooser)){
		$self->{error}=15;
		$self->{errorString}="'".$self->{args}{base}."/".$config."/.chooser' open failed.";
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
	}
	print WRITECHOOSER $chooserstring;
	close("WRITECHOOSER");		

	return (1);
}

=head2 writeChooserLDAP

This function is a internal function and largely meant to only be called
writeChooser, which it functions the same as. It works on the LDAP backend.

    $zconf->writeChooserLDAP("foo/bar", $chooserString)
	if($zconf->{error}){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	}

=cut

sub writeChooserLDAP{
	my ($self, $config, $chooserstring)= @_;
	my $function='writeChooserLDAP';

	$self->errorBlank;

	#return false if the config is not set
	if (!defined($config)){
		$self->{error}=25;
		$self->{errorString}='$config not defined';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;			
	}

	#return false if the config is not set
	if (!defined($chooserstring)){
		$self->{error}=40;
		$self->{errorString}='\$chooserstring not defined';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#make sure the config name is legit
	my ($error, $errorString)=$self->configNameCheck($config);
	if(defined($error)){
		$self->{error}=$error;
		$self->{errorString}=$errorString;
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#checks to make sure the config does exist
	if(!$self->configExistsLDAP($config)){
		$self->{error}=12;
		$self->{errorString}="'".$config."' does not exist.";
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;			
	}

	#checks if it is locked or not
	my $locked=$self->isConfigLockedLDAP($config);
	if ($self->{error}) {
		warn($self->{module}.' '.$function.': isconfigLockedLDAP errored');
		return undef;
	}
	if ($locked) {
		$self->{error}=45;
		$self->{errorString}='The config "'.$config.'" is locked';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	if(defined($self->{error})){
		return undef;
	}

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
		$self->{error}=13;
		$self->{errorString}="Expected DN, '".$dn."' not found.";
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}else{
		if($entry->dn ne $dn){
			$self->{error}=13;
			$self->{errorString}="Expected DN, '".$dn."' not found.";
			warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
			return undef;				
		}
	}

	#replace the zconfChooser entry and updated it
	$entry->replace(zconfChooser=>$chooserstring);
	$entry->update($ldap);

	return (1);
}


=head2 writeSetFromHash

This takes a hash and writes it to a config. It takes two arguements,
both of which are hashes.

The first hash contains

The second hash is the hash to be written to the config.

=head2 args hash

=head3 config

The config to write it to.

This is required.

=head3 set

This is the set name to use.

If not defined, the one will be choosen.

=head3 revision

This is the revision string to use.

This is primarily meant for internal usage and is suggested
that you don't touch this unless you really know what you
are doing.

    $zconf->writeSetFromHash({config=>"foo/bar"}, \%hash)
	if($zconf->{error}){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	}

=cut

#the overarching writeSetFromHash
sub writeSetFromHash{
	my $self=$_[0];
	my %args=%{$_[1]};
	my %hash = %{$_[2]};
	my $function='writeSetFromHash';

	$self->errorBlank;

	#return false if the config is not set
	if (!defined($args{config})){
		$self->{error}=25;
		$self->{errorString}='$config not defined';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;			
	}

	#make sure the config name is legit
	my ($error, $errorString)=$self->configNameCheck($args{config});
	if(defined($error)){
		$self->{error}=$error;
		$self->{errorString}=$errorString;
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}
		
	#checks to make sure the config does exist
	if(!$self->configExists($args{config})){
		$self->{error}=12;
		$self->{errorString}="'".$args{config}."' does not exist.";
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;			
	}

	#checks if it is locked or not
	my $locked=$self->isConfigLocked($args{config});
	if ($self->{error}) {
		warn($self->{module}.' '.$function.': isconfigLocked errored');
		return undef;
	}
	if ($locked) {
		$self->{error}=45;
		$self->{errorString}='The config "'.$args{config}.'" is locked';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#sets the set to default if it is not defined
	if (!defined($args{set})){
		$args{set}=$self->{args}{default};
	}

	my $returned=undef;

	#writes it
	if($self->{args}{backend} eq "file"){
		$returned=$self->writeSetFromHashFile(\%args, \%hash);
	}else{
		if($self->{args}{backend} eq "ldap"){
			$returned=$self->writeSetFromHashLDAP(\%args, \%hash);
		}
	}
		
	if(!defined($returned)){
		return undef;
	}

	#set the revision to the same thing as the previous backend did if we need to sync
	$args{revision}=$returned;

	#attempt to sync the set locally if not using the file backend
	if($self->{args}{backend} ne "file"){
		my $syncReturn;
		if (!$self->configExistsFile($args{config})) {
			$syncReturn=$self->createConfigFile($args{config});
			if (!$syncReturn){
				warn($self->{module}.' '.$function.': sync failed');
			}
		}
		$syncReturn=$self->writeSetFromHashFile(\%args, \%hash);
		if (!$syncReturn){
				warn("ZConf writeSetFromHash:9: Could not sync config to the file backend");
		}
	}

	return $returned;
}

=head2 writeSetFromHashFile

This takes a hash and writes it to a config for the file backend.
It takes two arguements, both of which are hashes.

The first hash contains

The second hash is the hash to be written to the config.

=head2 args hash

=head3 config

The config to write it to.

This is required.

=head3 set

This is the set name to use.

If not defined, the one will be choosen.

=head3 revision

This is the revision string to use.

This is primarily meant for internal usage and is suggested
that you don't touch this unless you really know what you
are doing.

    $zconf->writeSetFromHashFile({config=>"foo/bar"}, \%hash)
	if($zconf->{error}){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	}

=cut

#write out a config from a hash to the file backend
sub writeSetFromHashFile{
	my $self = $_[0];
	my %args=%{$_[1]};
	my %hash = %{$_[2]};
	my $function='writeSetFromHashFile';

	$self->errorBlank;

	#return false if the config is not set
	if (!defined($args{config})){
		$self->{error}=25;
		$self->{errorString}='$config not defined';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;			
	}

	#make sure the config name is legit
	my ($error, $errorString)=$self->configNameCheck($args{config});
	if(defined($error)){
		$self->{error}=$error;
		$self->{errorString}=$errorString;
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#sets the set to default if it is not defined
	if (!defined($args{set})){
		$args{set}=$self->chooseSet($args{set});
	}else{
		if($self->setNameLegit($args{set})){
			$self->{args}{default}=$args{set};
		}else{
			$self->{error}=27;
			$self->{errorString}="'".$args{set}."' is not a legit set name.";
			warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
			return undef
		}
	}
		
	#checks to make sure the config does exist
	if(!$self->configExistsFile($args{config})){
		$self->{error}=12;
		$self->{errorString}="'".$args{config}."' does not exist.";
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;			
	}

	#checks if it is locked or not
	my $locked=$self->isConfigLockedFile($args{config});
	if ($self->{error}) {
		warn($self->{module}.' '.$function.': isconfigLockedFile errored');
		return undef;
	}
	if ($locked) {
		$self->{error}=45;
		$self->{errorString}='The config "'.$args{config}.'" is locked';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}
		
	#the path to the file
	my $fullpath=$self->{args}{base}."/".$args{config}."/".$args{set};
	
	#used for building it
	my $zml=ZML->new;

	my $hashkeysInt=0;#used for intering through the list of hash keys
	#builds the ZML object
	my @hashkeys=keys(%hash);
	while(defined($hashkeys[$hashkeysInt])){
		#attempts to add the variable
		if ($hashkeys[$hashkeysInt] =~ /^\#/) {
			#process a meta variable
			if ($hashkeys[$hashkeysInt] =~ /^\#\!/) {
				my @metakeys=keys(%{$hash{ $hashkeys[$hashkeysInt] }});
				my $metaInt=0;
				while (defined( $metakeys[$metaInt] )) {
					$zml->addMeta($hashkeys[$hashkeysInt], $metakeys[$metaInt], $hash{ $hashkeys[$hashkeysInt] }{ $metakeys[$metaInt] } );
					#checks to verify there was no error
					#this is not a fatal error... skips it if it is not legit
					if(defined($zml->{error})){
						warn($self->{module}.' '.$function.':23: $zml->addMeta() returned '.
							 $zml->{error}.", '".$zml->{errorString}."'. Skipping variable '".
							 $hashkeys[$hashkeysInt]."' in '".$args{config}."'.");
					}
					$metaInt++;
				}
			}
			#process a meta variable
			if ($hashkeys[$hashkeysInt] =~ /^\#\#/) {
				my @metakeys=keys(%{$hash{ $hashkeys[$hashkeysInt] }});
				my $metaInt=0;
				while (defined( $metakeys[$metaInt] )) {
					$zml->addComment($hashkeys[$hashkeysInt], $metakeys[$metaInt], $hash{ $hashkeys[$hashkeysInt] }{ $metakeys[$metaInt] } );
					#checks to verify there was no error
					#this is not a fatal error... skips it if it is not legit
					if(defined($zml->{error})){
						warn($self->{module}.' '.$function.':23: $zml->addComment() returned '.
							 $zml->{error}.", '".$zml->{errorString}."'. Skipping variable '".
							 $hashkeys[$hashkeysInt]."' in '".$args{config}."'.");
					}
					$metaInt++;
				}
			}
		}else {
			$zml->addVar($hashkeys[$hashkeysInt], $hash{$hashkeys[$hashkeysInt]});
			#checks to verify there was no error
			#this is not a fatal error... skips it if it is not legit
			if(defined($zml->{error})){
				warn($self->{module}.' '.$function.':23: $zml->addVar returned '.
					 $zml->{error}.", '".$zml->{errorString}."'. Skipping variable '".
					 $hashkeys[$hashkeysInt]."' in '".$args{config}."'.");
			}
		}
			
		$hashkeysInt++;
	}

	#opens the file and returns if it can not
	#creates it if necesary
	if(!open("THEFILE", '>', $fullpath)){
		$self->{error}=15;
		$self->{errorString}="'".$self->{args}{base}."/".$args{config}."/.chooser' open failed";
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}
	print THEFILE $zml->string;
	close("THEFILE");

	#updates the revision
	my $revisionfile=$self->{args}{base}."/".$args{config}."/.revision";
	if (!defined($args{revision})) {
		$args{revision}=time.' '.hostname.' '.rand();
	}
	#opens the file and returns if it can not
	#creates it if necesary
	if(!open("THEREVISION", '>', $revisionfile)){
		$self->{error}=43;
		$self->{errorString}="'".$revisionfile."' open failed";
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}
	print THEREVISION $args{revision};
	close("THEREVISION");
	#saves the revision info
	$self->{revision}{$args{config}}=$args{revision};

	return $args{revision};
}

=head2 writeSetFromHashLDAP


This takes a hash and writes it to a config for the file backend.
It takes two arguements, both of which are hashes.

The first hash contains

The second hash is the hash to be written to the config.

=head2 args hash

=head3 config

The config to write it to.

This is required.

=head3 set

This is the set name to use.

If not defined, the one will be choosen.

=head3 revision

This is the revision string to use.

This is primarily meant for internal usage and is suggested
that you don't touch this unless you really know what you
are doing.

    $zconf->writeSetFromHashLDAP({config=>"foo/bar"}, \%hash)
	if($zconf->{error}){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	}

=cut

#write out a config from a hash to the LDAP backend
sub writeSetFromHashLDAP{
	my $self = $_[0];
	my %args=%{$_[1]};
	my %hash = %{$_[2]};
	my $function='writeSetFromHashLDAP';

	$self->errorBlank;

	#return false if the config is not set
	if (!defined($args{config})){
		$self->{error}=25;
		$self->{errorString}='$config not defined';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;			
	}

	#make sure the config name is legit
	my ($error, $errorString)=$self->configNameCheck($args{config});
	if(defined($error)){
		$self->{error}=$error;
		$self->{errorString}=$errorString;
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#sets the set to default if it is not defined
	if (!defined($args{set})){
		$args{set}=$self->chooseSet($args{set});
	}else{
		if($self->setNameLegit($args{set})){
			$self->{args}{default}=$args{set};
		}else{
			$self->{error}=27;
			$self->{errorString}="'".$args{set}."' is not a legit set name.";
			warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
			return undef
		}
	}

	#checks to make sure the config does exist
	if(!$self->configExistsLDAP($args{config})){
		$self->{error}=12;
		$self->{errorString}="'".$args{config}."' does not exist.";
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;			
	}

	#checks if it is locked or not
	my $locked=$self->isConfigLockedLDAP($args{config});
	if ($self->{error}) {
		warn($self->{module}.' '.$function.': isconfigLockedLDAP errored');
		return undef;
	}
	if ($locked) {
		$self->{error}=45;
		$self->{errorString}='The config "'.$args{config}.'" is locked';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#sets the set to default if it is not defined
	if (!defined($args{set})){
		$args{set}="default";
	}
		
	#sets the set to default if it is not defined
	if (!defined($args{autoCreateConfig})){
		$args{autoCreateConfig}="0";
	}
		
	my $zml=ZML->new;

	my $hashkeysInt=0;#used for intering through the list of hash keys
	#builds the ZML object
	my @hashkeys=keys(%hash);
	while(defined($hashkeys[$hashkeysInt])){
		#attempts to add the variable
		if ($hashkeys[$hashkeysInt] =~ /^\#/) {
			#process a meta variable
			if ($hashkeys[$hashkeysInt] =~ /^\#\!/) {
				my @metakeys=keys(%{$hash{ $hashkeys[$hashkeysInt] }});
				my $metaInt=0;
				while (defined( $metakeys[$metaInt] )) {
					$zml->addMeta($hashkeys[$hashkeysInt], $metakeys[$metaInt], $hash{ $hashkeys[$hashkeysInt] }{ $metakeys[$metaInt] } );
					#checks to verify there was no error
					#this is not a fatal error... skips it if it is not legit
					if(defined($zml->{error})){
						warn($self->{module}.' '.$function.':23: $zml->addMeta() returned '.
							 $zml->{error}.", '".$zml->{errorString}."'. Skipping variable '".
							 $hashkeys[$hashkeysInt]."' in '".$args{config}."'.");
					}
					$metaInt++;
				}
			}
			#process a meta variable
			if ($hashkeys[$hashkeysInt] =~ /^\#\#/) {
				my @metakeys=keys(%{$hash{ $hashkeys[$hashkeysInt] }});
				my $metaInt=0;
				while (defined( $metakeys[$metaInt] )) {
					$zml->addComment($hashkeys[$hashkeysInt], $metakeys[$metaInt], $hash{ $hashkeys[$hashkeysInt] }{ $metakeys[$metaInt] } );
					#checks to verify there was no error
					#this is not a fatal error... skips it if it is not legit
					if(defined($zml->{error})){
						warn($self->{module}.' '.$function.':23: $zml->addComment() returned '.
							 $zml->{error}.", '".$zml->{errorString}."'. Skipping variable '".
							 $hashkeys[$hashkeysInt]."' in '".$args{config}."'.");
					}
					$metaInt++;
				}
			}
		}else {
			$zml->addVar($hashkeys[$hashkeysInt], $hash{$hashkeys[$hashkeysInt]});
			#checks to verify there was no error
			#this is not a fatal error... skips it if it is not legit
			if(defined($zml->{error})){
				warn($self->{module}.' '.$function.':23: $zml->addVar returned '.
					 $zml->{error}.", '".$zml->{errorString}."'. Skipping variable '".
					 $hashkeys[$hashkeysInt]."' in '".$args{config}."'.");
			}
		}
			
		$hashkeysInt++;
	};

	#gets the setstring
	my $setstring=$args{set}."\n".$zml->string;
		
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
		$self->{error}=13;
		$self->{errorString}="Expected DN, '".$dn."' not found.";
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}else{
		if($entry->dn ne $dn){
			$self->{error}=13;
			$self->{errorString}="Expected DN, '".$dn."' not found.";
			warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
			return undef;				
		}
	}
	
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
			}
			$attributesInt++;
		}
		#if the set was not found, add it
		if(!$setFound){
			$entry->add(zconfSet=>$args{set});
		}
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
					}
				}
				$setFound=1;
			}
			$attributesInt++;
		}
		#if the config is not found, add it
		if(!$setFound){
				$entry->add(zconfData=>[$setstring]);
		}
	}else{
		$entry->add(zconfData=>$setstring);
	}

	#update the revision
	if (!defined($args{revision})) {
		$args{revision}=time.' '.hostname.' '.rand();
	}
	$entry->delete('zconfRev');
	$entry->add(zconfRev=>[$args{revision}]);

	#write the entry to LDAP
	my $results=$entry->update($ldap);

	#save the revision info
	$self->{revision}{$args{config}}=$args{revision};

	return $args{revision};
}

=head2 writeSetFromLoadedConfig

This function writes a loaded config to a to a set.

One arguement is required.

=head2 args hash

=head3 config

The config to write it to.

This is required.

=head3 set

This is the set name to use.

If not defined, the one will be choosen.

=head3 revision

This is the revision string to use.

This is primarily meant for internal usage and is suggested
that you don't touch this unless you really know what you
are doing.

    $zconf->writeSetFromLoadedConfig({config=>"foo/bar"});
	if($zconf->{error}){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	}

=cut

#the overarching writeSetFromLoadedConfig
sub writeSetFromLoadedConfig{
	my $self=$_[0];
	my %args= %{$_[1]};
	my $function='writeSetFromLoadedConfig';

	$self->errorBlank;

	#return false if the config is not set
	if (!defined($args{config})){
		$self->{error}=25;
		$self->{errorString}='$config not defined';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;			
	}

	if(!defined($self->{conf}{$args{config}})){
		$self->{error}=25;
		$self->{errorString}="Config '".$args{config}."' is not loaded";
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#checks if it is locked or not
	my $locked=$self->isConfigLocked($args{config});
	if ($self->{error}) {
		warn($self->{module}.' '.$function.': isconfigLocked errored');
		return undef;
	}
	if ($locked) {
		$self->{error}=45;
		$self->{errorString}='The config "'.$args{config}.'" is locked';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#sets the set to default if it is not defined
	if (!defined($args{set})){
		$args{set}=$self->{set}{$args{config}};
	}else{
		if($self->setNameLegit($args{set})){
			$self->{args}{default}=$args{set};
		}else{
			$self->{error}=27;
			$self->{errorString}="'".$args{set}."' is not a legit set name.";
			warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
			return undef
		}
	}

	my $returned=undef;

	#writes it
	if($self->{args}{backend} eq "file"){
		$returned=$self->writeSetFromLoadedConfigFile(\%args);
	}else{
		if($self->{args}{backend} eq "ldap"){
			$returned=$self->writeSetFromLoadedConfigLDAP(\%args);
		}
	}
		
	if(!defined($returned)){
		return undef;
	}

	#set the revision to the same thing as the previous backend did if we need to sync
	$args{revision}=$returned;

	#attempt to sync the set locally if not using the file backend
	if($self->{args}{backend} ne "file"){
		my $syncReturn;
		if (!$self->configExistsFile($args{config})) {
			$syncReturn=$self->createConfigFile($args{config});
			if (!$syncReturn){
				warn($self->{module}.' '.$function.': sync failed');
			}
		}
		$syncReturn=$self->writeSetFromLoadedConfigFile(\%args);
		if (!$syncReturn){
			warn("ZConf writeSetFromHash:9: Could not sync config to the file backend");
		}
	}

	return $returned;
}

=head2 writeSetFromLoadedConfigFile

This function writes a loaded config to a to a set,
for the file backend.

One arguement is required.

=head2 args hash

=head3 config

The config to write it to.

This is required.

=head3 set

This is the set name to use.

If not defined, the one will be choosen.

=head3 revision

This is the revision string to use.

This is primarily meant for internal usage and is suggested
that you don't touch this unless you really know what you
are doing.

    $zconf->writeSetFromLoadedConfigFile({config=>"foo/bar"}, %hash)
	if($zconf->{error}){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	}

=cut

#write a set out
sub writeSetFromLoadedConfigFile{
	my $self = $_[0];
	my %args=%{$_[1]};
	my $function='writeSetFromLoadedConfigFile';

	$self->errorBlank;

	#checks if it is locked or not
	my $locked=$self->isConfigLockedFile($args{config});
	if ($self->{error}) {
		warn($self->{module}.' '.$function.': isconfigLockedFile errored');
		return undef;
	}
	if ($locked) {
		$self->{error}=45;
		$self->{errorString}='The config "'.$args{config}.'" is locked';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#sets the set to default if it is not defined
	if (!defined($args{set})){
		$args{set}=$self->{set}{$args{config}};
	}else{
		if($self->setNameLegit($args{set})){
			$self->{args}{default}=$args{set};
		}else{
			$self->{error}=27;
			$self->{errorString}="'".$args{set}."' is not a legit set name.";
			warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
			return undef
		}
	}

	#the path to the file
	my $fullpath=$self->{args}{base}."/".$args{config}."/".$args{set};

	my $setstring="";

	#create the ZML object
	my $zml=ZML->new();

	#process variables
	my $varhashkeysInt=0;#used for intering through the list of hash keys
	#builds the ZML object
	my @varhashkeys=keys(%{$self->{conf}{$args{config}}});
	while(defined($varhashkeys[$varhashkeysInt])){
		#attempts to add the variable
		$zml->addVar($varhashkeys[$varhashkeysInt], 
					$self->{conf}{$args{config}}{$varhashkeys[$varhashkeysInt]});
		#checks to verify there was no error
		#this is not a fatal error... skips it if it is not legit
		if(defined($zml->{error})){
			warn('zconf writeSetFromLoadedConfigLDAP:23: $zml->add() returned '.
				$zml->{error}.", '".$zml->{errorString}."'. Skipping variable '".
				$varhashkeys[$varhashkeysInt]."' in '".$args{config}."'.");
		}

		$varhashkeysInt++;
	}

	#processes the meta variables
	my $varsInt=0;#used for intering through the list of hash keys
	#builds the ZML object
	my @vars=keys(%{$self->{meta}{$args{config}}});
	while(defined($vars[$varsInt])){
		my @metas=keys( %{$self->{meta}{ $args{config} }{ $vars[$varsInt] }} );
		my $metasInt=0;
		while (defined($metas[ $metasInt ])) {
			$zml->addMeta(
						  $vars[$varsInt],
						  $metas[$metasInt],
						  $self->{meta}{ $args{config} }{ $vars[$varsInt] }{ $metas[$metasInt] }
						  );
			$metasInt++;
		}
			
		$varsInt++;
	}

	#processes the comment variables
	$varhashkeysInt=0;#used for intering through the list of hash keys
	#builds the ZML object
	@varhashkeys=keys(%{$self->{comment}{$args{config}}});
	while(defined($varhashkeys[$varhashkeysInt])){
		my @commenthashkeys=keys( %{$self->{comment}{ $args{config} }{ $varhashkeys[$varhashkeysInt] }} );
		my $commenthashkeysInt=0;
		while (defined($commenthashkeys[ $commenthashkeysInt ])) {
			$zml->addComment(
							 $varhashkeys[$varhashkeysInt],
							 $commenthashkeys[$commenthashkeysInt],
							 $self->{comment}{ $args{config} }{ $varhashkeys[$varhashkeysInt] }{ $commenthashkeys[$commenthashkeysInt] }
							 );
			
			$commenthashkeysInt++;
		}
			
		$varhashkeysInt++;
	}

	#opens the file and returns if it can not
	#creates it if necesary
	if(!open("THEFILE", '>', $fullpath)){
		$self->{error}=15;
		$self->{errorString}="'".$self->{args}{base}."/".$args{config}."/.chooser' open failed.";
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}
	print THEFILE $zml->string();
	close("THEFILE");

	#updates the revision
	my $revisionfile=$self->{args}{base}."/".$args{config}."/.revision";
	if (!defined($args{revision})) {
		$args{revision}=time.' '.hostname.' '.rand();
	}
	
	#opens the file and returns if it can not
	#creates it if necesary
	if(!open("THEREVISION", '>', $revisionfile)){
		$self->{error}=43;
		$self->{errorString}="'".$revisionfile."' open failed";
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}
	print THEREVISION $args{revision};
	close("THEREVISION");
	#save the revision info
	$self->{revision}{$args{config}}=$args{revision};

	return $args{revision};
}

=head2 writeSetFromLoadedConfigLDAP

This function writes a loaded config to a to a set,
for the LDAP backend.

One arguement is required.

=head2 args hash

=head3 config

The config to write it to.

This is required.

=head3 set

This is the set name to use.

If not defined, the one will be choosen.

=head3 revision

This is the revision string to use.

This is primarily meant for internal usage and is suggested
that you don't touch this unless you really know what you
are doing.

    $zconf->writeSetFromLoadedConfigLDAP({config=>"foo/bar"});
	if(defined($zconf->{error})){
		print 'error: '.$zconf->{error}."\n".$zconf->errorString."\n";
	}

=cut

#write a set out to LDAP
sub writeSetFromLoadedConfigLDAP{
	my $self = $_[0];
	my %args=%{$_[1]};
	my $function='writeSetFromLoadedConfigLDAP';

	$self->errorBlank;

	#checks if it is locked or not
	my $locked=$self->isConfigLockedLDAP($args{config});
	if ($self->{error}) {
		warn($self->{module}.' '.$function.': isconfigLockedLDAP errored');
		return undef;
	}
	if ($locked) {
		$self->{error}=45;
		$self->{errorString}='The config "'.$args{config}.'" is locked';
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#sets the set to default if it is not defined
	if (!defined($args{set})){
		$args{set}=$self->{set}{$args{config}};
	}else{
		if($self->setNameLegit($args{set})){
			$self->{args}{default}=$args{set};
		}else{
			$self->{error}=27;
			$self->{errorString}="'".$args{set}."' is not a legit set name.";
			warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
			return undef
		}
	}

	#get a list of keys
	my @varhashkeys=keys(%{$self->{conf}{$args{config}}});

	#create the ZML object
	my $zml=ZML->new();
		
	my $varhashkeysInt=0;#used for intering through the list of hash keys
	#builds the ZML object
	while(defined($varhashkeys[$varhashkeysInt])){
		#attempts to add the variable
		$zml->addVar($varhashkeys[$varhashkeysInt], 
					$self->{conf}{$args{config}}{$varhashkeys[$varhashkeysInt]});
		#checks to verify there was no error
		#this is not a fatal error... skips it if it is not legit
		if(defined($zml->{error})){
			warn('zconf writeSetFromLoadedConfigLDAP:23: $zml->addMeta() returned '.
				$zml->{error}.", '".$zml->{errorString}."'. Skipping variable '".
				$varhashkeys[$varhashkeysInt]."' in '".$args{config}."'.");
		}

		$varhashkeysInt++;
	}

	#processes the meta variables
	$varhashkeysInt=0;#used for intering through the list of hash keys
	#builds the ZML object
	@varhashkeys=keys(%{$self->{meta}{$args{config}}});
	while(defined($varhashkeys[$varhashkeysInt])){
		my @metahashkeys=keys( %{$self->{meta}{ $args{config} }{ $varhashkeys[$varhashkeysInt] }} );
		my $metahashkeysInt=0;
		while (defined($metahashkeys[ $metahashkeysInt ])) {
			$zml->addMeta(
						  $varhashkeys[$varhashkeysInt],
						  $metahashkeys[$metahashkeysInt],
						  $self->{meta}{ $args{config} }{ $varhashkeys[$varhashkeysInt] }{ $metahashkeys[$metahashkeysInt] }
						  );
			
			$metahashkeysInt++;
		}
			
		$varhashkeysInt++;
	}

	#processes the comment variables
	$varhashkeysInt=0;#used for intering through the list of hash keys
	#builds the ZML object
	@varhashkeys=keys(%{$self->{comment}{$args{config}}});
	while(defined($varhashkeys[$varhashkeysInt])){
		my @commenthashkeys=keys( %{$self->{comment}{ $args{config} }{ $varhashkeys[$varhashkeysInt] }} );
		my $commenthashkeysInt=0;
		while (defined($commenthashkeys[ $commenthashkeysInt ])) {
			$zml->addComment(
						  $varhashkeys[$varhashkeysInt],
						  $commenthashkeys[$commenthashkeysInt],
						  $self->{comment}{ $args{config} }{ $varhashkeys[$varhashkeysInt] }{ $commenthashkeys[$commenthashkeysInt] }
						  );
			
			$commenthashkeysInt++;
		}
			
		$varhashkeysInt++;
	}

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
		$self->{error}=13;
		$self->{errorString}="Expected DN, '".$dn."' not found.";
		warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}else{
		if($entry->dn ne $dn){
			$self->{error}=13;
			$self->{errorString}="Expected DN, '".$dn."' not found.";
			warn($self->{module}.' '.$function.':'.$self->{error}.': '.$self->{errorString});
			return undef;				
		}
	}

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
		}
		#if the set was not found, add it
		if(!$setFound){
			$entry->add(zconfSet=>$args{set});
		}
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
					}
				}
				$setFound=1;
			}
			$attributesInt++;
		}
		#if the config is not found, add it
		if(!$setFound){
			$entry->add(zconfData=>[$setstring]);
		}
	}else{
		$entry->add(zconfData=>$setstring);
	}

	#update the revision
	if (!defined($args{revision})) {
		$args{revision}=time.' '.hostname.' '.rand();
	}
	$entry->delete('zconfRev');
	$entry->add(zconfRev=>[$args{revision}]);

	my $results=$entry->update($ldap);

	#save the revision info
	$self->{revision}{$args{config}}=$args{revision};

	return $args{revision};
}

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

Any variable name is legit as long it does not match any of the following. This also
covers comments and meta variables.

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

No variable name specified.

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

=head2 36

Could not create '/var/db/zconf'. This is a permanent error.

=head2 37

Could not create '/var/db/zconf/<sys name>'. This is a permanent error.

=head2 38

Sys name matched /\//.

=head2 39

Sys name matched /\./.

=head2 40

No chooser string specified.

=head2 41

No comment specified.

=head2 42

No meta specified.

=head2 43

Failed to open the revision file for the set.

=head2 44

Failed to open or unlink lock file.

=head2 45

Config is locked.

=head1 ERROR CHECKING

This can be done by checking $zconf->{error} to see if it is defined. If it is defined,
The number it contains is the corresponding error code. A description of the error can also
be found in $zconf->{errorString}, which is set to "" when there is no error.

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

=head3 ldap/<profile>/cafile

When verifying the server's certificate, either set capath to the pathname of the directory containing
CA certificates, or set cafile to the filename containing the certificate of the CA who signed the
server's certificate. These certificates must all be in PEM format.

=head3 ldap/<profile>/capath

The directory in 'capath' must contain certificates named using the hash value of the certificates'
subject names. To generate these names, use OpenSSL like this in Unix:

    ln -s cacert.pem `openssl x509 -hash -noout < cacert.pem`.0

(assuming that the certificate of the CA is in cacert.pem.)

=head3 ldap/<profile>/checkcrl

If capath has been configured, then it will also be searched for certificate revocation lists (CRLs)
when verifying the server's certificate. The CRLs' names must follow the form hash.rnum where hash
is the hash over the issuer's DN and num is a number starting with 0.

=head3 ldap/<profile>/clientcert

This client cert to use.

=head3 ldap/<profile>/clientkey

The client key to use.

Encrypted keys are not currently supported at this time.

=head3 ldap/<profile>/homeDN

This is the home DN of the user in question. The user needs be able to write to it. ZConf
will attempt to create 'ou=zconf,ou=.config,$homeDN' for operating out of.

=head3 ldap/<profile>/host

This is the server to use for LDAP connections.

=head3 ldap/<profile>/password

This is the password to use for when connecting to the server.

=head3 ldap/<profile>/passwordfile

Read the password from this file. If both this and password is set,
then this will write over it.

=head3 ldap/<profile>/starttls

This is if it should use starttls or not. It defaults to undefined, 'false'.

=head3 ldap/<profile>/SSLciphers

This is a list of ciphers to accept. The string is in the standard OpenSSL
format. The default value is 'ALL'.

=head3 ldap/<profile>/SSLversion

This is the SSL versions accepted.

'sslv2', 'sslv3', 'sslv2/3', or 'tlsv1' are the possible values. The default
is 'tlsv1'.

=head3 ldap/<profile>/TLSverify

The verify mode for TLS. The default is 'none'.

=head1 ZConf LDAP Schema

    # 1.3.6.1.4.1.26481 Zane C. Bowers
    #  .2 ldap
    #   .7 zconf
    #    .0 zconfData
    #    .1 zconfChooser
    #    .2 zconfSet
    #    .3 zconfRev
    #    .4 zconfLock
    
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
    
    attributeType ( 1.3.6.1.4.1.26481.2.7.3
        NAME 'zconfRev'
        DESC 'The revision number for a ZConf config. Bumped with each update.'
        SYNTAX 1.3.6.1.4.1.1466.115.121.1.15
        EQUALITY caseExactMatch
        )
    
    attributeType ( 1.3.6.1.4.1.26481.2.7.4
        NAME 'zconfLock'
        DESC 'If this is present, this config is locked.'
        SYNTAX 1.3.6.1.4.1.1466.115.121.1.15
        EQUALITY caseExactMatch
        )
    
    objectclass ( 1.3.6.1.4.1.26481.2.7
        NAME 'zconf'
        DESC 'A zconf entry.'
        MAY ( cn $ zconfData $ zconfChooser $ zconfSet $ zconfRev $ zconfLock )
        )

=head1 SYSTEM MODE

This is for deamons or the like. This will read
'/var/db/zconf/$sys/zconf.zml' for it's options and store
the file backend stuff in '/var/db/zconf/$sys/'.

It will create '/var/db/zconf' or the sys directory, but not
'/var/db'.

=head1 UTILITIES

There are several scripts installed with this module. Please see the perldocs for
the utilities listed below.

    zcchooser-edit
    zcchooser-get
    zcchooser-run
    zcchooser-set
    zccreate
    zcget
    zcls
    zcrm
    zcset
    zcvdel
    zcvls


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
