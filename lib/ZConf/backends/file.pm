package ZConf::backends::file;

use File::Path;
use File::BaseDir qw/xdg_config_home/;
use Chooser;
use warnings;
use strict;
use ZML;
use Sys::Hostname;

=head1 NAME

ZConf::backends::file - A configuration system allowing for either file or LDAP backed storage.

=head1 VERSION

Version 0.0.1

=cut

our $VERSION = '0.0.1';

=head1 SYNOPSIS

    use ZConf;

	#creates a new instance
    my $zconf = ZConf->new();
    ...

=head1 METHODS

=head2 new

	my $zconf=ZConf->(\%args);

This initiates the ZConf object. If it can't be initiated, a value of undef
is returned. The hash can contain various initization options.

When it is run for the first time, it creates a filesystem only config file.

=head3 args hash

=head4 sys

This turns system mode on. And sets it to the specified system name.

This is incompatible with the file option.

=head4 self

This is the copy of the ZConf object intiating it.

=head4 zconf

This is the variables found in the ~/.config/zconf.zml.

    my $zconf=ZConf::backends::file->new(\%args);
    if((!defined($zconf)) || ($zconf->{error})){
		warn('error: '.$zconf->error.":".$zconf->errorString);
    }

=cut

#create it...
sub new {
	my %args;
	if(defined($_[1])){
		%args= %{$_[1]};
	};
	my $method='new';

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
	my $self = {conf=>{}, args=>\%args, set=>{}, zconf=>{}, user=>{}, error=>undef,
				errorString=>"", meta=>{}, comment=>{}, module=>__PACKAGE__,
				revision=>{}, locked=>{}, autoupdateGlobal=>1, autoupdate=>{}};
	bless $self;

	#####################################
	#real in the stuff from the arguments
	#make sure we have a ZConf object
	if (!defined( $args{self} )) {
		$self->{error}=47;
		$self->{errorString}='No ZConf object passed';
		warn($self->{module}.' '.$method.':'.$self->{error}.': '.$self->{errorString});
		return $self;
	}
	if ( ref($args{self}) ne 'ZConf' ) {
		$self->{error}=47;
		$self->{errorString}='No ZConf object passed. ref returned "'.ref( $args{self} ).'"';
		warn($self->{module}.' '.$method.':'.$self->{error}.': '.$self->{errorString});
		return $self;
	}
	$self->{self}=$args{self};
	if (!defined( $args{zconf} )) {
		$self->{error}=48;
		$self->{errorString}='No zconf.zml var hash passed';
		warn($self->{module}.' '.$method.':'.$self->{error}.': '.$self->{errorString});
		return $self;		
	}
	if ( ref($args{zconf}) ne 'HASH' ) {
		$self->{error}=48;
		$self->{errorString}='No zconf.zml var hash passed. ref returned "'.ref( $args{zconf} ).'"';
		warn($self->{module}.' '.$method.':'.$self->{error}.': '.$self->{errorString});
		return $self;
	}
	$self->{zconf}=$args{zconf};
	#####################################

	#sets the base directory
	if (!defined($self->{args}{sys})) {
		$self->{args}{base}=xdg_config_home()."/zconf/";
	}else {
		$self->{args}{base}='/var/db/zconf/'.$self->{args}{sys};

		#make sure it will only be one directory
		if ($self->{args}{sys} =~ /\//) {
				$self->{error}='38';
				$self->{errorString}='Sys name,"'.$self->{args}{base}.'", matches /\//';
				warn($self->{module}.' '.$method.':'.$self->{error}.': '.$self->{errorString});
				return $self;
		}

		#make sure it is not hidden
		if ($self->{args}{sys} =~ /\./) {
				$self->{error}='39';
				$self->{errorString}='Sys name,"'.$self->{args}{base}.'", matches /\./';
				warn($self->{module}.' '.$method.':'.$self->{error}.': '.$self->{errorString});
				return $self;
		}

		#make sure the system directory exists
		if (!-d '/var/db/zconf') {
			if (!mkdir('/var/db/zconf')) {
				$self->{error}='36';
				$self->{errorString}='Could not create "/var/db/zconf/"';
				warn($self->{module}.' '.$method.':'.$self->{error}.': '.$self->{errorString});
				return $self;
			}
		}

		#make sure the 
		if (!-d $self->{args}{base}) {
			if (!mkdir($self->{args}{base})) {
				$self->{error}='37';
				$self->{errorString}='Could not create "'.$self->{args}{base}.'"';
				warn($self->{module}.' '.$method.':'.$self->{error}.': '.$self->{errorString});
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

	#get what the file only arg should be
	#this is a Perl boolean value
	if(!defined($self->{zconf}{fileonly})){
		$self->{zconf}->{args}{fileonly}="0";
	}else{
		$self->{args}{fileonly}=$self->{zconf}{fileonly};
	}

	return $self;
}

=head2 configExists

This method methods exactly the same as configExists, but
for the file backend.

No config name checking is done to verify if it is a legit name or not
as that is done in configExists. The same is true for calling errorBlank.

    $zconf->configExistsFile("foo/bar");
	if($zconf->error){
		warn('error: '.$zconf->{error}.":".$zconf->errorString);
	}

=cut

#checks if a file config exists 
sub configExists{
	my ($self, $config) = @_;
	my $method='configExists';

	$self->errorBlank;

	#makes the path if it does not exist
	if(!-d $self->{args}{base}."/".$config){
		return 0;
	}
		
	return 1;
}

=head2 createConfig

This methods just like createConfig, but is for the file backend.
This is not really meant for external use. The config name passed
is not checked to see if it is legit or not.

    $zconf->createConfigFile("foo/bar");
	if($zconf->error){
		warn('error: '.$zconf->error.":".$zconf->errorString);
	}

=cut

#creates a new config file as well as the default set
sub createConfig{
	my ($self, $config) = @_;
	my $method='createConfig';

	$self->errorBlank;

	#makes the path if it does not exist
	if(!mkpath($self->{args}{base}."/".$config)){
		$self->{error}=16;
		$self->{errorString}="'".$self->{args}{base}."/".$config."' creation failed.";
		warn($self->{module}.' '.$method.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	return 1;
}

=head2 delConfig

This removes a config. Any sub configs will need to removes first. If any are
present, this method will error.

    #removes 'foo/bar'
    $zconf->delConfig('foo/bar');
    if(defined($zconf->error)){
		warn('error: '.$zconf->error."\n".$zconf->errorString);
    }

=cut

sub delConfig{
	my $self=$_[0];
	my $config=$_[1];
	my $method='delConfig';

	$self->errorBlank;

	#return if this can't be completed
	if (defined($self->{error})) {
		return undef;		
	}

	my @subs=$self->getSubConfigs($config);
	#return if there are any sub configs
	if (defined($subs[0])) {
		$self->{error}='33';
		$self->{errorString}='Could not remove the config as it has sub configs';
		warn($self->{module}.' '.$method.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#makes sure it exists before continuing
	#This will also make sure the config exists.
	my $returned = $self->configExists($config);
	if (defined($self->{error})){
		$self->{error}='12';
		$self->{errorString}='The config, "'.$config.'", does not exist';
		warn($self->{module}.' '.$method.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	my @sets=$self->getAvailableSets($config);
	if (defined($self->{error})) {
		warn('zconf delConfigFile: getAvailableSetsFile set an error');
		return undef;
	}

	#goes through and removes each set before deleting
	my $setsInt='0';#used for intering through @sets
	while (defined($sets[$setsInt])) {
		#removes a set
		$self->delSet($config, $sets[$setsInt]);
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
		warn($self->{module}.' '.$method.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	return 1;
}

=head2 delSet

This deletes a specified set, for the filesystem backend.

Two arguements are required. The first one is the name of the config and the and
the second is the name of the set.

    $zconf->delSetFile("foo/bar", "someset");
    if($zconf->error){
		warn('error: '.$zconf->error.":".$zconf->errorString);
    }

=cut

sub delSet{
	my $self=$_[0];
	my $config=$_[1];
	my $set=$_[2];
	my $method='delSet';

	$self->errorBlank;

	#return if no set is given
	if (!defined($set)){
		$self->{error}=24;
		$self->{errorString}='$set not defined';
		warn($self->{module}.' '.$method.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#return if no config is given
	if (!defined($config)){
		$self->{error}=25;
		$self->{errorString}='$config not defined';
		warn($self->{module}.' '.$method.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#the path to the config
	my $configpath=$self->{args}{base}."/".$config;

	#returns with an error if it could not be set
	if (!-d $configpath) {
		$self->{error}=14;
		$self->{errorString}='"'.$config.'" is not a directory or does not exist';
		warn($self->{module}.' '.$method.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}
	
	#the path to the set
	my $fullpath=$configpath."/".$set;

	if (!unlink($fullpath)) {
		$self->{error}=29;
		$self->{errorString}='"'.$fullpath.'" could not be unlinked.';
		warn($self->{module}.' '.$method.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	return 1;
}

=head2 getAvailableSets

This is exactly the same as getAvailableSets, but for the file back end.
For the most part it is not intended to be called directly.

	my @sets = $zconf->getAvailableSets("foo/bar");
	if($zconf->error){
		warn('error: '.$zconf->error.":".$zconf->errorString);
	}

=cut

#this gets a set for a given file backed config
sub getAvailableSets{
	my ($self, $config) = @_;
	my $method='getAvailableSets';

	$self->errorBlank;

	#returns 0 if the config does not exist
	if (!-d $self->{args}{base}."/".$config) {
		$self->{error}=14;
		$self->{errorString}="'".$self->{args}{base}."/".$config."' does not exist.";
		warn($self->{module}.' '.$method.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	if (!opendir(CONFIGDIR, $self->{args}{base}."/".$config)) {
		$self->{error}=15;
		$self->{errorString}="'".$self->{args}{base}."/".$config."' open failed.";
		warn($self->{module}.' '.$method.':'.$self->{error}.': '.$self->{errorString});
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

=head2 getConfigRevision

This fetches the revision for the speified config using
the file backend.

A return of undef means that the config has no sets created for it
yet or it has not been read yet by 2.0.0 or newer.

    my $revision=$zconf->getConfigRevision('some/config');
    if($zconf->error){
		warn('error: '.$zconf->error.":".$zconf->errorString);
    }
    if(!defined($revision)){
        print "This config has had no sets added since being created or is from a old version of ZConf.\n";
    }

=cut

sub getConfigRevision{
	my $self=$_[0];
	my $config=$_[1];
	my $method='getConfigRevision';

	$self->errorBlank;

	#return false if the config is not set
	if (!defined($config)){
		$self->{error}=25;
		$self->{errorString}='No config specified';
		warn($self->{module}.' '.$method.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#checks to make sure the config does exist
	if(!$self->configExists($config)){
		$self->{error}=12;
		$self->{errorString}="'".$config."' does not exist.";
		warn($self->{module}.' '.$method.':'.$self->{error}.': '.$self->{errorString});
		return undef;			
	}

	#
	my $revisionfile=$self->{args}{base}."/".$config."/.revision";

	my $revision;
	if ( -f $revisionfile) {
		if(!open("THEREVISION", '<', $revisionfile)){
			warn($self->{module}.' '.$method.':43: '."'".$revisionfile."' open failed");
		}
		$revision=join('', <THEREVISION>);
		close(THEREVISION);
	}

	return $revision;
}

=head2 getSubConfigs

This gets any sub configs for a config. "" can be used to get a list of configs
under the root.

One arguement is accepted and that is the config to look under.

    #lets assume 'foo/bar' exists, this would return
    my @subConfigs=$zconf->getSubConfigs("foo");
    if($zconf->error){
		warn('error: '.$zconf->error.":".$zconf->errorString);
    }

=cut

#gets the configs under a config
sub getSubConfigs{
	my ($self, $config)= @_;
	my $method='getSubConfigsFile';

	$self->errorBlank;

	#returns 0 if the config does not exist
	if(!-d $self->{args}{base}."/".$config){
		$self->{error}=14;
		$self->{errorString}="'".$self->{args}{base}."/".$config."' does not exist.";
		warn($self->{module}.' '.$method.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	if(!opendir(CONFIGDIR, $self->{args}{base}."/".$config)){
		$self->{error}=15;
		$self->{errorString}="'".$self->{args}{base}."/".$config."' open failed.";
		warn($self->{module}.' '.$method.':'.$self->{error}.': '.$self->{errorString});
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

=head2 isConfigLocked

This checks if a config is locked or not for the file backend.

One arguement is required and it is the name of the config.

The returned value is a boolean value.

    my $locked=$zconf->isConfigLockedFile('some/config');
    if($zconf->error){
		warn('error: '.$zconf->error.":".$zconf->errorString);
    }
    if($locked){
        print "The config is locked\n";
    }

=cut

sub isConfigLocked{
	my $self=$_[0];
	my $config=$_[1];
	my $method='isConfigLocked';

	$self->errorBlank;

	#return false if the config is not set
	if (!defined($config)){
		$self->{error}=25;
		$self->{errorString}='No config specified';
		warn($self->{module}.' '.$method.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#makes sure it exists
	my $exists=$self->configExists($config);
    if ($self->{error}) {
		warn($self->{module}.' '.$method.': configExists errored');
		return undef;
	}
	if (!$exists) {
		$self->{error}=12;
		$self->{errorString}='The config, "'.$config.'", does not exist';
		warn($self->{module}.' '.$method.':'.$self->{error}.': '.$self->{errorString});
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

=head2 read

readFile methods just like read, but is mainly intended for internal use
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
	if($zconf->error){
		warn('error: '.$zconf->error.":".$zconf->errorString);
	}

=cut

#read a config from a file
sub read{
	my $self=$_[0];
	my %args=%{$_[1]};
	my $method='read';

	$self->errorBlank;

	#return false if the config is not set
	if (!defined($args{config})){
		$self->{error}=25;
		$self->{errorString}='$config not defined';
		warn($self->{module}.' '.$method.':'.$self->{error}.': '.$self->{errorString});
		return undef;			
	}

	#return false if the config is not set
	if (!defined($args{set})){
		$self->{error}=24;
		$self->{errorString}='$arg{set} not defined';
		warn($self->{module}.' '.$method.':'.$self->{error}.': '.$self->{errorString});
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
		warn($self->{module}.' '.$method.':'.$self->{errror}.': '.$self->{errorString});
		return undef;
	}

	#at this point we save the stuff in it
	$self->{self}->{conf}{$args{config}}=\%{$zml->{var}};
	$self->{self}->{meta}{$args{config}}=\%{$zml->{meta}};
	$self->{self}->{comment}{$args{config}}=\%{$zml->{comment}};

	#sets the set that was read		
	$self->{self}->{set}{$args{config}}=$args{set};

	#updates the revision
	my $revisionfile=$self->{args}{base}."/".$args{config}."/.revision";
	#opens the file and returns if it can not
	#creates it if necesary
	if ( -f $revisionfile) {
		if(!open("THEREVISION", '<', $revisionfile)){
			warn($self->{module}.' '.$method.':43: '."'".$revisionfile."' open failed");
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
			warn($self->{module}.' '.$method.':'.$self->{error}.': '.$self->{errorString});
			return undef;
		}
		print THEREVISION $self->{revision}{$args{config}};
		close("THEREVISION");
	}

	#checks if it is locked or not and save it
	my $locked=$self->isConfigLocked($args{config});
	if ($locked) {
		$self->{locked}{$args{config}}=1;
	}

	#run the overrides if requested tox
	if ($args{override}) {
		#runs the override if not locked
		if (!$locked) {
			$self->{self}->override({ config=>$args{config} });
		}
	}

	return $self->{self}->{revision}{$args{config}};
}

=head2 readChooser

This methods just like readChooser, but methods on the file backend
and only really intended for internal use.

	my $chooser = $zconf->readChooserFile("foo/bar");
	if($zconf->error){
		warn('error: '.$zconf->error.":".$zconf->errorString);
	}

=cut

#this gets the chooser for a the config... for the file backend
sub readChooser{
	my ($self, $config)= @_;
	my $method='readChooser';

	$self->errorBlank;

	#return false if the config is not set
	if (!defined($config)){
		$self->{error}=25;
		$self->{errorString}='$config not defined';
		warn($self->{module}.' '.$method.':'.$self->{error}.': '.$self->{errorString});
		return undef;			
	}

	#make sure the config name is legit
	my ($error, $errorString)=$self->{self}->configNameCheck($config);
	if(defined($error)){
		$self->{error}=$error;
		$self->{errorString}=$errorString;
		warn($self->{module}.' '.$method.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}
		
	#checks to make sure the config does exist
	if(!$self->configExists($config)){
		$self->{error}=12;
		$self->{errorString}="'".$config."' does not exist.";
		warn($self->{module}.' '.$method.':'.$self->{error}.': '.$self->{errorString});
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
		warn($self->{module}.' '.$method.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}
	my $chooserstring=<READCHOOSER>;
	close("READCHOOSER");		

	return ($chooserstring);
}

=head2 setExists

This checks if the specified set exists.

Two arguements are required. The first arguement is the name of the config.
The second arguement is the name of the set. If no set is specified, the default
set is used. This is done by calling 'defaultSetExists'.

    my $return=$zconf->setExists("foo/bar", "fubar");
    if($zconf->error){
		warn('error: '.$zconf->error.":".$zconf->errorString);
    }else{
        if($return){
            print "It exists.\n";
        }
    }

=cut

sub setExists{
	my ($self, $config, $set)= @_;
	my $method='setExists';

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

This unlocks or logs a config for the file backend.

Two arguements are taken. The first is a
the config name, required, and the second is
if it should be locked or unlocked

    #lock 'some/config'
    $zconf->setLockConfigFile('some/config', 1);
    if($zconf->error){
		warn('error: '.$zconf->error.":".$zconf->errorString);
    }

    #unlock 'some/config'
    $zconf->setLockConfigFile('some/config', 0);
    if($zconf->error){
		warn('error: '.$zconf->error.":".$zconf->errorString);
    }

    #unlock 'some/config'
    $zconf->setLockConfigFile('some/config');
    if($zconf->error){
		warn('error: '.$zconf->error.":".$zconf->errorString);
    }

=cut

sub setLockConfig{
	my $self=$_[0];
	my $config=$_[1];
	my $lock=$_[2];
	my $method='setLockConfig';

	$self->errorBlank;

	#return false if the config is not set
	if (!defined($config)){
		$self->{error}=25;
		$self->{errorString}='No config specified';
		warn($self->{module}.' '.$method.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#makes sure it exists
	my $exists=$self->configExists($config);
    if ($self->{error}) {
		warn($self->{module}.' '.$method.': configExists errored');
		return undef;
	}
	if (!$exists) {
		$self->{error}=12;
		$self->{errorString}='The config, "'.$config.'", does not exist';
		warn($self->{module}.' '.$method.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#locks the config
	my $lockfile=$self->{args}{base}."/".$config."/.lock";

	#handles locking it
	if ($lock) {
		if(!open("THELOCK", '>', $lockfile)){
			$self->{error}=44;
			$self->{errorString}="'".$lockfile."' open failed";
			warn($self->{module}.' '.$method.':'.$self->{error}.': '.$self->{errorString});
			return undef;
        }
        print THELOCK time."\n".hostname;
        close("THELOCK");
		#return now that it is locked
		return 1;
	}

	#handles unlocking it
	if (-e $lockfile) { #don't error if it is already unlocked
		if (!unlink($lockfile)) {
			$self->{error}=44;
			$self->{errorString}='"'.$lockfile.'" could not be unlinked.';
			warn($self->{module}.' '.$method.':'.$self->{error}.': '.$self->{errorString});
			return undef;
		}
	}

	return 1;
}

=head2 writeChooser

This method is a internal method and largely meant to only be called
writeChooser, which it methods the same as. It works on the file backend.

	$zconf->writeChooserFile("foo/bar", $chooserString)
	if($zconf->error){
		warn('error: '.$zconf->error.":".$zconf->errorString);
	}

=cut

sub writeChooser{
	my ($self, $config, $chooserstring)= @_;
	my $method='writeChooser';

	$self->errorBlank;

	#return false if the config is not set
	if (!defined($config)){
		$self->{error}=25;
		$self->{errorString}='$config not defined';
		warn($self->{module}.' '.$method.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#checks if it is locked or not
	my $locked=$self->isConfigLocked($config);
	if ($self->{error}) {
		warn($self->{module}.' '.$method.': isconfigLockedFile errored');
		return undef;
	}
	if ($locked) {
		$self->{error}=45;
		$self->{errorString}='The config "'.$config.'" is locked';
		warn($self->{module}.' '.$method.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#return false if the config is not set
	if (!defined($chooserstring)){
		$self->{error}=40;
		$self->{errorString}='\$chooserstring not defined';
		warn($self->{module}.' '.$method.':'.$self->{error}.': '.$self->{errorString});
		return undef;			
	}

	#make sure the config name is legit
	my ($error, $errorString)=$self->{self}->configNameCheck($config);
	if(defined($error)){
		$self->{error}=$error;
		$self->{errorString}=$errorString;
		warn($self->{module}.' '.$method.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	my $chooser=$self->{args}{base}."/".$config."/.chooser";

	#open the file and get the string error on not being able to open it 
	if(!open("WRITECHOOSER", ">", $chooser)){
		$self->{error}=15;
		$self->{errorString}="'".$self->{args}{base}."/".$config."/.chooser' open failed.";
		warn($self->{module}.' '.$method.':'.$self->{error}.': '.$self->{errorString});
	}
	print WRITECHOOSER $chooserstring;
	close("WRITECHOOSER");		

	return (1);
}

=head2 writeSetFromHash

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
	if($zconf->error){
		warn('error: '.$zconf->error.":".$zconf->errorString);
	}

=cut

#write out a config from a hash to the file backend
sub writeSetFromHash{
	my $self = $_[0];
	my %args=%{$_[1]};
	my %hash = %{$_[2]};
	my $method='writeSetFromHash';

	$self->errorBlank;

	#return false if the config is not set
	if (!defined($args{config})){
		$self->{error}=25;
		$self->{errorString}='$config not defined';
		warn($self->{module}.' '.$method.':'.$self->{error}.': '.$self->{errorString});
		return undef;			
	}

	#make sure the config name is legit
	my ($error, $errorString)=$self->{self}->configNameCheck($args{config});
	if(defined($error)){
		$self->{error}=$error;
		$self->{errorString}=$errorString;
		warn($self->{module}.' '.$method.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#sets the set to default if it is not defined
	if (!defined($args{set})){
		$args{set}=$self->{self}->chooseSet($args{set});
	}else{
		if($self->{self}->setNameLegit($args{set})){
			$self->{args}{default}=$args{set};
		}else{
			$self->{error}=27;
			$self->{errorString}="'".$args{set}."' is not a legit set name.";
			warn($self->{module}.' '.$method.':'.$self->{error}.': '.$self->{errorString});
			return undef
		}
	}
		
	#checks to make sure the config does exist
	if(!$self->configExists($args{config})){
		$self->{error}=12;
		$self->{errorString}="'".$args{config}."' does not exist.";
		warn($self->{module}.' '.$method.':'.$self->{error}.': '.$self->{errorString});
		return undef;			
	}

	#checks if it is locked or not
	my $locked=$self->isConfigLocked($args{config});
	if ($self->{error}) {
		warn($self->{module}.' '.$method.': isconfigLockedFile errored');
		return undef;
	}
	if ($locked) {
		$self->{error}=45;
		$self->{errorString}='The config "'.$args{config}.'" is locked';
		warn($self->{module}.' '.$method.':'.$self->{error}.': '.$self->{errorString});
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
						warn($self->{module}.' '.$method.':23: $zml->addMeta() returned '.
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
						warn($self->{module}.' '.$method.':23: $zml->addComment() returned '.
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
				warn($self->{module}.' '.$method.':23: $zml->addVar returned '.
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
		warn($self->{module}.' '.$method.':'.$self->{error}.': '.$self->{errorString});
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
		warn($self->{module}.' '.$method.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}
	print THEREVISION $args{revision};
	close("THEREVISION");
	#saves the revision info
	$self->{self}->{revision}{$args{config}}=$args{revision};

	return $args{revision};
}

=head2 writeSetFromLoadedConfig

This method writes a loaded config to a to a set,
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
	if($zconf->error){
		warn('error: '.$zconf->error.":".$zconf->errorString);
	}

=cut

#write a set out
sub writeSetFromLoadedConfig{
	my $self = $_[0];
	my %args=%{$_[1]};
	my $method='writeSetFromLoadedConfig';

	$self->errorBlank;

	#return false if the config is not set
	if (!defined($args{config})){
		$self->{error}=25;
		$self->{errorString}='$config not defined';
		warn($self->{module}.' '.$method.':'.$self->{error}.': '.$self->{errorString});
		return undef;			
	}

	if(! $self->{self}->isConfigLoaded( $args{config} ) ){
		$self->{error}=25;
		$self->{errorString}="Config '".$args{config}."' is not loaded";
		warn($self->{module}.' '.$method.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#checks if it is locked or not
	my $locked=$self->isConfigLocked($args{config});
	if ($self->{error}) {
		warn($self->{module}.' '.$method.': isconfigLockedFile errored');
		return undef;
	}
	if ($locked) {
		$self->{error}=45;
		$self->{errorString}='The config "'.$args{config}.'" is locked';
		warn($self->{module}.' '.$method.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}

	#sets the set to default if it is not defined
	if (!defined($args{set})){
		$args{set}=$self->{set}{$args{config}};
	}else{
		if($self->{self}->setNameLegit($args{set})){
			$self->{args}{default}=$args{set};
		}else{
			$self->{error}=27;
			$self->{errorString}="'".$args{set}."' is not a legit set name.";
			warn($self->{module}.' '.$method.':'.$self->{error}.': '.$self->{errorString});
			return undef
		}
	}

	#the path to the file
	my $fullpath=$self->{args}{base}."/".$args{config}."/".$args{set};

	my $zml=$self->{self}->dumpToZML($args{config});
	if ($self->{self}->error) {
			$self->{error}=14;
			$self->{errorString}='Failed to dump to ZML. error='.$self->{self}->error.' errorString='.$self->{self}->errorString;
			warn($self->{module}.' '.$method.':'.$self->{error}.': '.$self->{errorString});
			return undef		
	}

	#opens the file and returns if it can not
	#creates it if necesary
	if(!open("THEFILE", '>', $fullpath)){
		$self->{error}=15;
		$self->{errorString}="'".$self->{args}{base}."/".$args{config}."/.chooser' open failed.";
		warn($self->{module}.' '.$method.':'.$self->{error}.': '.$self->{errorString});
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
		warn($self->{module}.' '.$method.':'.$self->{error}.': '.$self->{errorString});
		return undef;
	}
	print THEREVISION $args{revision};
	close("THEREVISION");
	#save the revision info
	$self->{self}->{revision}{$args{config}}=$args{revision};

	return $args{revision};
}

=head1 ERROR RELATED METHODS

=head2 error

Returns the current error code and true if there is an error.

If there is no error, undef is returned.

    if( $zconf->error ){
		warn('error: '.$zconf->error.":".$zconf->errorString);
    }

=cut

sub error{
    return $_[0]->{error};
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

=head2 errorString

Returns the error string if there is one. If there is not,
it will return ''.

    if( $zconf->error ){
		warn('error: '.$zconf->error.":".$zconf->errorString);
    }

=cut

sub errorString{
    return $_[0]->{errorString};
}

=head1 ERROR CODES

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

=head2 46

LDAP entry update failed.

=head2 47

No ZConf object passed.

=head2 48

No zconf.zml var hash passed.

=head1 ERROR CHECKING

This can be done by checking $zconf->{error} to see if it is defined. If it is defined,
The number it contains is the corresponding error code. A description of the error can also
be found in $zconf->{errorString}, which is set to "" when there is no error.

=head1 zconf.zml

The default is 'xdf_config_home/zconf.zml', which is generally '~/.config/zconf.zml'. See perldoc
ZML for more information on the file format. The keys are listed below.

=head2 keys

=head3 backend

This should be set to 'ldap' to use this backend.

=head1 SYSTEM MODE

This is for deamons or the like. This will read
'/var/db/zconf/$sys/zconf.zml' for it's options and store
the file backend stuff in '/var/db/zconf/$sys/'.

It will create '/var/db/zconf' or the sys directory, but not
'/var/db'.

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
