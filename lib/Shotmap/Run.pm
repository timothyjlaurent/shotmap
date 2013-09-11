#!/usr/bin/perl -w

#Shotmap::Run.pm - Handles workhorse methods in the shotmap workflow
#Copyright (C) 2011  Thomas J. Sharpton 
#author contact: thomas.sharpton@gladstone.ucsf.edu
#
#This program is free software: you can redistribute it and/or modify
#it under the terms of the GNU General Public License as published by
#the Free Software Foundation, either version 3 of the License, or
#(at your option) any later version.
#    
#This program is distributed in the hope that it will be useful,
#but WITHOUT ANY WARRANTY; without even the implied warranty of
#MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#GNU General Public License for more details.
#    
#You should have received a copy of the GNU General Public License
#along with this program (see LICENSE.txt).  If not, see 
#<http://www.gnu.org/licenses/>.

package Shotmap::Run;

use strict;
use Shotmap;
use Shotmap::DB;
use Data::Dumper;
use File::Basename;
use File::Cat;
use File::Copy;
use File::Path;
use IPC::System::Simple qw(capture $EXITVAL);
use IO::Uncompress::Gunzip qw(gunzip $GunzipError);
use IO::Compress::Gzip qw(gzip $GzipError);
use Bio::SearchIO;
use DBIx::Class::ResultClass::HashRefInflator;
use Benchmark;
use File::Spec;
use List::Util qw( shuffle );

# ServerAliveInterval : in SECONDS
# ServerAliveCountMax : number of times to keep the connection alive
# Total keep-alive time in minutes = (ServerAliveInterval*ServerAliveCountMax)/60 minutes
my $GLOBAL_SSH_TIMEOUT_OPTIONS_STRING = '-o TCPKeepAlive=no -o ServerAliveInterval=30 -o ServerAliveCountMax=480';

my $HMMDB_DIR = "HMMdbs";
my $BLASTDB_DIR = "BLASTdbs";

sub remote_transfer_scp{
    my ($self, $src_path, $dest_path, $path_type) = @_;
    ($path_type eq 'directory' or $path_type eq 'file') or die "unsupported path type! must be 'file' or 'directory'. Yours was: '$path_type'.";
    my $COMPRESSION_FLAG = '-C';
    my $PRESERVE_MODIFICATION_TIMES = '-p';
    my $RECURSIVE_FLAG = ($path_type eq 'directory') ? '-r' : ''; # only specify recursion if DIRECTORIES are being transferred!
    my $FLAGS = "$COMPRESSION_FLAG $RECURSIVE_FLAG $PRESERVE_MODIFICATION_TIMES";
    my @args = ($FLAGS, $GLOBAL_SSH_TIMEOUT_OPTIONS_STRING, $src_path, $dest_path);
    $self->Shotmap::Notify::notifyAboutScp("scp @args");
    my $results = IPC::System::Simple::capture("scp @args");
    (0 == $EXITVAL) or die("Error transferring $src_path to $dest_path using $path_type: $results");
    return $results;
}

#rolling over to rsync for directories
sub remote_transfer {
    my ($self, $src_path, $dest_path, $path_type) = @_;
    ($path_type eq 'directory' or $path_type eq 'file') or die "unsupported path type! must be 'file' or 'directory'. Yours was: '$path_type'.";
    my $COMPRESSION_FLAG = '--compress';
    my $PRESERVE_MODIFICATION_TIMES = '--times';
    my $PRESERVE_PERMISSIONS_FLAG = '--perms';
    my $RECURSIVE_FLAG = ($path_type eq 'directory') ? '--recursive' : ''; # only specify recursion if DIRECTORIES are being transferred!
    my $FLAGS = "$COMPRESSION_FLAG $RECURSIVE_FLAG $PRESERVE_MODIFICATION_TIMES $PRESERVE_PERMISSIONS_FLAG";
    #my @args = ($FLAGS, $GLOBAL_SSH_TIMEOUT_OPTIONS_STRING, $src_path, $dest_path);
    my @args = ($FLAGS, $src_path, $dest_path);
    $self->Shotmap::Notify::notifyAboutScp("rsync @args");
    #This is to ensure that the folder is created on the rremote host
    my @dest_flds = split(":", $dest_path);
    my $results = IPC::System::Simple::capture("ssh $dest_flds[0] mkdir -p $dest_flds[1]");
    (0 == $EXITVAL) or die("Error creating $dest_path: $results");
    $results = IPC::System::Simple::capture("rsync @args");
    (0 == $EXITVAL) or die("Error transferring $src_path to $dest_path using $path_type: $results");
    return $results;
}


sub ends_in_a_slash($) { return ($_[0] =~ /\/$/); } # return whether or not the first (and only) argument to this function ends in a forward slash (/)

sub transfer_file {
    my ($self, $src_path, $dest_path) = @_;
    (!ends_in_a_slash($src_path))  or die "Since you are transferring a FILE to a new FILE location, the source must not end in a slash.  Your source was <$src_path>, and destination was <$dest_path>.";
    (!ends_in_a_slash($dest_path)) or die "Since you are transferring a FILE to a new FILE location, the destination must not end in a slash. This will be the new location of the file, NOT the name of the parent directory. Your source was <$src_path>, and destination was <$dest_path>. If you want to transfer a file INTO a directory, use the function transfer_file_into_directory instead.";
    return( $self->Shotmap::Run::remote_transfer($src_path, $dest_path, 'file'));
}

sub transfer_directory{
    # Transfer a directory between machines / locations.
    # Example:
    # src_path:  remote.machine.place.ed:/somewhere/over/the/rainbow
    # dest_path:  /local/machine/rainbow
    # Note that the last directory ("rainbow") must be the same in both cases! You CANNOT use this function to rename files while they are transferred.
    # Also, src_path and dest_path must both NOT end in slashes!
    my ($self, $src_path, $dest_path) = @_;
    my $src_base  = File::Basename::basename($src_path );
    my $dest_base = File::Basename::basename($dest_path);
    (!ends_in_a_slash($src_path))  or die "Since you are transferring a DIRECTORY, the source must not end in a slash.  Your source was <$src_path>, and destination was <$dest_path>.";
    (!ends_in_a_slash($dest_path)) or die "Since you are transferring a DIRECTORY, the destination must not end in a slash. This will be the new location of the directory, NOT the name of the parent directory. Your source was <$src_path>, and destination was <$dest_path>.";
    ($src_base eq $dest_base) or die "Directory transfer problem: The last directory in the source path \"$src_path\" must exactly match the last directory in the \"$dest_path\"! Example: transferring /some/place to /other/place is OK, but transferring /some/place to /other/placeTWO is NOT OK, because the ending of the source part ('place') is different from the ending of the destination part ('placeTWO')!";
    my $dest_parent_dir_with_slash = File::Basename::dirname($dest_path) . "/"; # include the slash so we don't actually OVERWRITE this directory if it doesn't already exist
    return( $self->Shotmap::Run::remote_transfer($src_path, $dest_parent_dir_with_slash, 'directory'));
}

sub transfer_file_into_directory {
    # source: a file (that does NOT end in a slash!)
    # destination: a directory (that ends with a slash!)
    my ($self, $src_path, $dest_path) = @_;
    (!ends_in_a_slash($src_path)) or die "Since you are transferring a FILE, the source must not end in a slash (the slash indicates that the source is a DIRECTORY, which is probably incorrect). Your source file was <$src_path> and destination file was <$dest_path>.";
    (ends_in_a_slash($dest_path)) or die "Since you are transferring a file INTO a directory, the destination path MUST END IN A SLASH (indicating that it is a destination directory. Otherwise, it is ambiguous as to whether you want to transfer the file INTO the directory, or if you want the file to be written to OVERWRITE that directory. Your source file was <$src_path> and destination file was <$dest_path>.";
    return( $self->Shotmap::Run::remote_transfer($src_path, $dest_path, 'file'));
}


sub execute_ssh_cmd{
    my ($self, $connection, $remote_cmd, $verbose) = @_;
    my $verboseFlag = (defined($verbose) && $verbose) ? '-v' : '';
    my $sshOptions = "ssh $GLOBAL_SSH_TIMEOUT_OPTIONS_STRING $verboseFlag $connection";
    $self->Shotmap::Notify::notifyAboutRemoteCmd($sshOptions);
    $self->Shotmap::Notify::notifyAboutRemoteCmd($remote_cmd);
    my $results = IPC::System::Simple::capture("$sshOptions $remote_cmd");
    (0 == $EXITVAL) or die( "Error running this ssh command: $sshOptions $remote_cmd: $results" );
    return $results; ## <-- this gets used! Don't remove it.
}


sub get_sequence_length_from_file($) {
    my($file) = shift;
    #my $READSTRING = ($file =~ m/\.gz/ ) ? "zmore $file | " : "$file"; # allow transparent reading of gzipped files via 'zmore'
    open(FILE, "zcat --force $file |") || die "Unable to open the file \"$file\" for reading: $! --"; # zcat --force can TRANSPARENTLY read both .gz and non-gzipped files!
    my $seqLength = 0;
    while(<FILE>){
	next if ($_ =~ m/^\>/); # skip lines that start with a '>'
	chomp $_; # remove the newline
	$seqLength += length($_);
    }
    close FILE;
    if ($seqLength == 0) { warn "Uh oh, we got a sequence length of ZERO from the file <$file>. This could indicate a serious problem!"; }
    return $seqLength; # return the sequence length
}

sub gzip_file($) {
    my($file) = @_;
    IO::Compress::Gzip::gzip $file => "${file}.gz" or die "gzip failed: $GzipError ";
}

sub clean_project{
    my ($self, $project_id) = @_;
    my $samples = $self->Shotmap::DB::get_samples_by_project_id( $project_id ); # apparently $samples is a scalar datatype that we can iterate over
    $self->Shotmap::DB::delete_project( $project_id );
    $self->Shotmap::DB::delete_ffdb_project( $project_id );
}

sub exec_remote_cmd($$) {
    my ($self, $remote_cmd) = @_;
    my $connection = $self->remote_connection();
    if ($remote_cmd =~ /\'/) {
	die "Remote commands aren't allowed to include the single quote character currently. Sorry!";
    }
    my $sshCmd = "ssh $GLOBAL_SSH_TIMEOUT_OPTIONS_STRING -v $connection '$remote_cmd' "; # remote-cmd gets single quotes around it!
    $self->Shotmap::Notify::notifyAboutRemoteCmd($sshCmd);
    my $results = IPC::System::Simple::capture($sshCmd);
    (0 == $EXITVAL) or die( "Error running this remote command: $sshCmd: $results" );
    return $results; ## <-- this gets used! Don't remove it.
}


#currently uses @suffix with basename to successfully parse off .fa. may need to change
sub get_partitioned_samples{
    my ($self, $path) = @_;
    my %samples = ();        
    opendir( PROJ, $path ) || die "Can't open the directory $path for read: $!\n";     #open the directory and get the sample names and paths, 
    my @files = readdir(PROJ);
    closedir(PROJ);
    foreach my $file (@files) {
	next if ( $file =~ m/^\./ || $file =~ m/hmmscan/ || $file =~ m/output/); 
	next if ( -d "$path/$file" ); # skip directories, apparently
	#if there's a project description file, grab the information
	if($file =~ m/project_description\.txt/){ # <-- see if there's a description file
	    my $text = '';
	    open(DESC, "$path/$file") || die "Can't open project description file $file for read: $!. Project is $path.\n";
	    while(<DESC>){
		$text .= $_; # append the line
	    }
	    close(DESC);
	    undef $text if( $text eq '' );
	    $self->project_desc($text);
	} elsif( $file =~ m/sample_metadata\.tab/ ){  #if there's a sample metadata table, grab the information
	    my $text = '';
	    open( META, "$path/$file" ) || die "Can't open sample metadata table for read: $!. Project is $path.\n";
	    while(<META>){
		$text .= $_;
	    }
	    #check that the file is properly formatted	   
	    if( $text !~ m/^Sample_name/ ){
		die( "You did not specify a properly formatted sample_metadata.tab file. Please ensure that the first row contains properly " .
		     "formatted column labels. See the manual for more information\n" );
	    }	   
	    my @rows  = split( "\n", $text );
	    my $ncols = 0;
	    foreach my $row( @rows ){
		my @cols = split( "\t", $row );
		my $row_n_col = scalar( @cols );
		if( $ncols == 0 ){
		    $ncols = $row_n_col;
		} elsif( $ncols != $row_n_col) {
		    die( "You do not have an equal number of tab-delimited columns in every row of your sample_metadata.tab file. Please double check " .
			 "your format. See the manual for more information\n" );
		} else { #looks good
		    next;
		}
	    }
	    close META;
	    undef $text if( $text eq '' );
	    $self->sample_metadata($text);
	}
	else {
	    #get sample name here, simple parse on the period in file name
    	    my $thisSample = basename($file, (".fa", ".fna"));
	    $samples{$thisSample}->{"path"} = "$path/$file";
	}	
    }
    if( !defined( $self->project_desc() ) ){
	warn( "You didn't provide a project description file, which is optional. " .
	      "Note that you can describe your project in the database via a project_description.txt file. See manual for more informaiton\n" );
    }
    if( !defined( $self->sample_metadata() ) ){
	warn( "You didn't provide a sample metadata file, which is optional. " . 
	      "Note that you can describe your samples in the database via a sample_metadata.tab file. See manual for more informaiton\n" );
    }
    warn("Adding samples to analysis object at path <$path>.");
    $self->set_samples( \%samples );
    #return $self;
}

sub load_project{
    my ($self, $path, $nseqs_per_samp_split) = @_;    # $nseqs_per_samp_split is how many seqs should each sample split file contain?
    my ($name, $dir, $suffix) = fileparse( $path );     #get project name and load
    my $proj = $self->Shotmap::DB::create_project($name, $self->project_desc() );
    #store vars in object
    $self->project_path($path);
    $self->project_id($proj->project_id());
    #process the samples associated with project
    $self->Shotmap::Run::load_samples();
    $self->Shotmap::DB::build_project_ffdb();
    $self->Shotmap::DB::build_sample_ffdb($nseqs_per_samp_split); #this also splits the sample file
    warn("Project with PID " . $proj->project_id() . ", with files found at <$path>, was successfully loaded!\n");
}

sub load_samples{
    my ($self) = @_;
    my %samples = %{$self->get_sample_hashref()}; # de-reference the hash reference
    my $numSamples = scalar( keys(%samples) );
    my $plural = ($numSamples == 1) ? '' : 's'; # pluralize 'samples'
    $self->Shotmap::Notify::notify("Run.pm: load_samples: Processing $numSamples sample${plural} associated with project PID #" . $self->project_id() . " ");
    my $metadata = {};
    #if it exists, grab each sample's metadata
    if( defined( $self->sample_metadata ) ){
	my @rows = split( "\n", $self->sample_metadata );
	my $header = shift( @rows );
	my @colnames = split( "\t", $header );
	foreach my $row( @rows ){ #all rows except the header
	    print $row . "\n";
	    my @cols = split( "\t", $row );
	    my $samp_alt_id = $cols[0];
	    my $metadata_string;
	    for( my $i=1; $i < scalar(@cols); $i++){
		my $key   = $colnames[$i];
		my $value = $cols[$i]; 
		if( $i == 1 ){
		    $metadata_string = $key . "=" . $value;
		} else {
		    $metadata_string = join( ",", $metadata_string, $key . "=" . $value );
		}
	    }
	    print "$metadata_string\n";
	    $metadata->{$samp_alt_id} = $metadata_string;       
	}
    }
    #load each sample
    foreach my $samp( keys( %samples ) ){
	my $pid = $self->project_id();
	my $insert;	
	my $metadata_string;
	if( defined( $self->sample_metadata ) ){
	    $metadata_string = $metadata->{$samp};
	}	
	eval { # <-- this is like a "try" (in the "try/catch" sense)
	    $insert = $self->Shotmap::DB::create_sample($samp, $pid, $metadata_string );
	};
	if ($@) { # <-- this is like a "catch" block in the try/catch sense. "$@" is the exception message (a human-readable string).
	    # Caught an exception! Probably create_sample complained about a duplicate entry in the database!
	    my $errMsg = $@;
	    chomp($errMsg);
	    if ($errMsg =~ m/duplicate entry/i) {
		print STDERR ("*" x 80 . "\n");
		print STDERR ("DATABASE INSERTION ERROR\nCaught an exception when attempting to add sample \"$samp\" for project PID #${pid} to the database.\nThe exception message was:\n$errMsg\n");
		print STDERR ("Note that the error above was a DUPLICATE ENTRY error.\nThis is a VERY COMMON error, and is due to the database already having a sample/project ID with the same number as the one we are attempting to insert. This most often happens if a run is interrupted---so there is an entry in the database for your project run, but there are no files on the filesystem for it, since it did not complete the run. The solution to this problem is to manually remove the entries for project id #$pid from the Mysql database. Are you sure that you want to reprocess a dataset from scratch? If so, you can remove the old data from the database via thee different options:\n");
		print STDERR ("You can do this as follows:\n");
		print STDERR (" Option A: Rerun your mcr_handler.pl command, but add the --reload option\n" );
		print STDERR (" Option B: Use MySQL to remove the old data, as follows:\n" );
		print STDERR ("   1. Go to your database server (probably " . $self->get_db_hostname() . ")\n");
		print STDERR ("   2. Log into mysql with this command: mysql -u YOURNAME -p   <--- YOURNAME is probably \"" . $self->get_username() . "\"\n");
		print STDERR ("   3. Type these commands in mysql: use ***THE DATABASE***;   <--- THE DATABASE is probably " . $self->get_db_name() . "\n");
		print STDERR ("   4.                        mysql: select * from project;    <--- just to look at the projects.\n");
		print STDERR ("   5.                        mysql: delete from project where project_id=${pid};    <-- actually deletes this project.\n");
		print STDERR ("   6. Then you can log out of mysql and hopefully re-run this script successfully!\n");
		print STDERR ("   7. You MAY also need to delete the entry from the 'samples' table in MySQL that has the same name as this sample/proejct.\n");
		print STDERR ("   8. Try connecting to mysql, then typing 'select * from samples;' . You should see an OLD project ID (but with the same textual name as this one) that may be preventing you from running another analysis. Delete that id ('delete from samples where sample_id=the_bad_id;'");
		my $mrcCleanCommand = (qq{perl \$Shotmap_LOCAL/scripts/mrc_clean_project.pl} 
				       . qq{ --pid=}    . $pid
				       . qq{ --dbuser=} . $self->get_username()
				       . qq{ --dbpass=} . "PUT_YOUR_PASSWORD_HERE"
				       . qq{ --dbhost=} . $self->get_db_hostname()
				       . qq{ --ffdb=}   . $self->ffdb()
				       . qq{ --dbname=} . $self->get_db_name()
				       . qq{ --schema=} . $self->{"schema_name"});
		print STDERR (" Option C: Run mrc_cleand_project.pl as follows:\n" );
		print STDERR ("$mrcCleanCommand\n");
		print STDERR ("*" x 80 . "\n");
		die "Terminating: Duplicate database entry error! See above for a possible solution.";
	    }
	    die "Terminating: Database insertion error! See the message above for more details..."; # no "newline" with die!
	}

	$samples{$samp}->{"id"} = $insert->sample_id();
	my $sid                 = $insert->sample_id(); # just a short name for the sample ID above
	if( $self->bulk_load() ){
	    my $tmp    = "/tmp/" . $samp . ".sql";	    
	    my $table  = "metareads";
	    my $nrows  = 10000;
	    my @fields = ( "sample_id", "read_alt_id", "seq" );
	    my $fks    = { "sample_id" => $sid }; #foreign keys and fields not in file 
            #unless( $self->is_slim() ){ #we require reads to be loaded so that we can scale rarefaction analysis later
	    $self->Shotmap::DB::bulk_import( $table, $samples{$samp}->{"path"}, $tmp, $nrows, $fks, \@fields );
	    #} #from the commented unless block above
	}
	else{
	    #could speed this up by getting out of bioperl...
	    my $seqs                = Bio::SeqIO->new( -file => $samples{$samp}->{"path"}, -format => 'fasta' );
	    my $numReads            = 0;
	    #unless( $self->is_slim() ){ #we require reads to be loaded so that we can scale rarefaction analysis later
    	      if ($self->is_multiload()) {
		  my @read_names = (); # empty list to start...
		  while (my $read = $seqs->next_seq()) {
		      my $read_name = $read->display_id();
		      push( @read_names, $read_name );
		      $numReads++;
		  }
		  $self->Shotmap::DB::create_multi_metareads( $sid, \@read_names );
	      } else{
		  while (my $read = $seqs->next_seq()) { ## If we AREN'T multi-loading, then do this...
		      my $read_name = $read->display_id();
		      $self->Shotmap::DB::create_metaread($read_name, $sid);
		      $numReads++;
		  }
	      }
	      $self->Shotmap::Notify::notify("Loaded $numReads reads for sample $sid into the database.");
	}
    }
    $self->set_samples(\%samples);
    $self->Shotmap::Notify::notify("Successfully loaded $numSamples sample$plural associated with the project PID #" . $self->project_id() . " ");
}

sub load_families{
    my( $self, $type, $db_name ) = @_;
    my $raw_db_path = undef;
    if ($type eq "hmm")   { $raw_db_path = $self->search_db_path("hmm"); }
    if ($type eq "blast") { $raw_db_path = $self->search_db_path("blast"); }
    my $file =  "${raw_db_path}/family_lengths.tab";
    if( $self->bulk_load() ){
	my $tmp    = "/tmp/famlens.sql";	    
	my $table  = "families";
	my $nrows  = 10000;
	my @fields = ( "famid", "family_length", "family_size" );
	my $fks    = { "searchdb_id" => $self->Shotmap::DB::get_searchdb_id( $db_name, $type ) }; #foreign keys and fields not in file 
	$self->Shotmap::DB::bulk_import( $table, $file, $tmp, $nrows, $fks, \@fields );
    }
    return $self;
}

sub load_family_members{
    my( $self, $type, $db_name ) = @_;
    my $file = $self->search_db_path("blast") . "/sequence_lengths.tab";
    if( $self->bulk_load() ){
	my $tmp    = "/tmp/seqlens.sql";	    
	my $table  = "familymembers";
	my $nrows  = 10000;
	my @fields = ( "famid", "target_id", "target_length" );
	my $fks    = { "searchdb_id" => $self->Shotmap::DB::get_searchdb_id( $db_name, $type ) }; #foreign keys and fields not in file 
	$self->Shotmap::DB::bulk_import( $table, $file, $tmp, $nrows, $fks, \@fields );
    }
    return $self;
}

sub check_family_loadings{
    my( $self, $type, $db_name ) = @_;
    my $bit = 0;
    my $raw_db_path = undef;
    if ($type eq "hmm")   { $raw_db_path = $self->search_db_path("hmm"); }
    if ($type eq "blast") { $raw_db_path = $self->search_db_path("blast"); }
    my $famlen_tab  = "${raw_db_path}/family_lengths.tab";
    my $searchdb_id = $self->Shotmap::DB::get_searchdb_id( $type, $db_name );
    my $ff_rows     = _count_lines_in_file( $famlen_tab );
    my $sql_rows    = $self->Shotmap::DB::get_families_by_searchdb_id( $searchdb_id)->count();
    $bit = 1 if( $ff_rows == $sql_rows );
    return $bit;
}

sub check_familymember_loadings{
    my( $self, $type, $db_name ) = @_;
    my $bit = 0;
    my $raw_db_path = undef;
    if ($type eq "hmm")   { $raw_db_path = $self->search_db_path("hmm"); }
    if ($type eq "blast") { $raw_db_path = $self->search_db_path("blast"); }
    my $seqlen_tab  = "${raw_db_path}/sequence_lengths.tab";
    my $searchdb_id = $self->Shotmap::DB::get_searchdb_id( $type, $db_name );
    my $ff_rows     = _count_lines_in_file( $seqlen_tab );
    my $sql_rows    = $self->Shotmap::DB::get_familymembers_by_searchdb_id( $searchdb_id)->count();
    $bit = 1 if( $ff_rows == $sql_rows );
    return $bit;
}

sub _count_lines_in_file{
    my $file = shift;
    open( FILE, $file ) || die "can't open $file for read: $!\n";
    my $count = 0;
    while( <FILE> ){
	$count++;
    }
    close FILE;
    return $count;
}

sub build_read_import_file{
    my $self      = shift;
    my $seqs      = shift;
    my $sample_id = shift;
    my $out       = shift;
    open( SEQS, "$seqs" ) || die "Can't open $seqs for read in Shotmap::Run::build_read_import_file\n";
    open( OUT,  ">$out" ) || die "Can't open $out for write in Shotmap::Run::build_read_import_file\n";
    while( <SEQS> ){
	chomp $_;
	if( $_ =~ m/^\>(.*)(\s|$)/ ){
	    my $read_alt_id = $1;
	    print OUT "$sample_id,$read_alt_id\n";
	}
    }
    return $self;
}

sub back_load_project(){
    my $self = shift;
    my $project_id = shift;
    my $ffdb = $self->ffdb();
    my $dbname = $self->db_name();
    $self->project_id( $project_id );
    $self->project_path("$ffdb/projects/$dbname/$project_id");
    if( $self->remote ){
	$self->remote_script_path(      "hmmscan",      $self->remote_project_path() . "/run_hmmscan.sh" );
	$self->remote_script_path(    "hmmsearch",    $self->remote_project_path() . "/run_hmmsearch.sh" );
        $self->remote_script_path(        "blast",        $self->remote_project_path() . "/run_blast.sh" );
        $self->remote_script_path(     "formatdb",     $self->remote_project_path() . "/run_formatdb.sh" );
        $self->remote_script_path(       "lastdb",       $self->remote_project_path() . "/run_lastdb.sh" );
        $self->remote_script_path(         "last",         $self->remote_project_path() . "/run_last.sh" );
	$self->remote_script_path(    "rapsearch",    $self->remote_project_path() . "/run_rapsearch.sh");
	$self->remote_script_path( "prerapsearch", $self->remote_project_path() . "/run_prerapsearch.sh");
	$self->remote_project_log_dir(     $self->remote_project_path() . "/logs" );
    }
}

#this might need extra work to get the "path" element correct foreach sample
sub back_load_samples{
    my $self = shift;
    my $project_id = $self->project_id();
    my $project_path = $self->get_project_path();
    opendir( PROJ, $project_path ) || die "can't open $project_path for read: $!\n";
    my @files = readdir( PROJ );
    closedir PROJ;
    my %samples = ();
    foreach my $file( @files ){
	next if ( $file =~ m/^\./ || $file =~ m/logs/ || $file =~ m/hmmscan/ || $file =~ m/output/ || $file =~ m/\.sh/ );
	my $sample_id = $file;
	my $samp    = $self->Shotmap::DB::get_sample_by_sample_id( $sample_id );
#	my $sample_name = $samp->name();
#	$samples{$sample_name}->{"id"} = $sample_id;
	my $sample_alt_id = $samp->sample_alt_id();
	$samples{$sample_alt_id}->{"id"} = $sample_id;
    }
    $self->set_samples( \%samples );
    #back load remote data
    warn("Back-loading of samples is now complete.");
    #return $self;
}

# Note this message: "this is a compute side function. don't use db vars"
sub translate_reads {
    my ($self, $input, $output) = @_;

    (-d $input) or die "Unexpectedly, the input directory <$input> was NOT FOUND! Check to see if this directory really exists.";
    (-d $output) or die "Unexpectedly, the output directory <$output> was NOT FOUND! Check to see if this directory really exists.";
    my $results  = IPC::System::Simple::capture("transeq $input $output -frame=6");
    (0 == $EXITVAL) or die("Error translating sequences in $input -> $output. Result was: $results ");
    return $results;
}


sub load_multi_orfs{
    my ($self, $orfsBioSeqObject, $sample_id, $algo) = @_;   # $orfsBioSeqObject is a Bio::Seq object
    my %orfHash       = (); #orf_alt_id to read_id
    my %readHash      = (); #read_alt_id to read_id
    my $numOrfsLoaded = 0;
    while (my $orf = $orfsBioSeqObject->next_seq() ){
	my $orf_alt_id  = $orf->display_id();
	my $read_alt_id = $self->Shotmap::Run::parse_orf_id( $orf_alt_id, $algo );
	#get the read id, but only if we haven't see this read before
	my $read_id = undef;
	if(defined($readHash{$read_alt_id} ) ){
	    $read_id = $readHash{$read_alt_id};
	} else{
	    my $reads = $self->get_schema->resultset("Metaread")->search( { read_alt_id => $read_alt_id, sample_id   => $sample_id } ); # "search" takes some kind of anonymous hash or whatever this { } thing is
	    if ($reads->count() > 1) { die("Found multiple reads that match read_alt_id: $read_alt_id and sample_id: $sample_id in load_orf. Cannot continue!"); }
	    my $read = $reads->next();
	    $read_id = $read->read_id();
	    $readHash{ $read_alt_id } = $read_id;
	}
	$orfHash{ $orf_alt_id } = $read_id;
	$numOrfsLoaded++;
    }
    $self->Shotmap::DB::insert_multi_orfs( $sample_id, \%orfHash );
    $self->Shotmap::Notify::notify("Bulk loaded a total of <$numOrfsLoaded> orfs to the database.");
    ($numOrfsLoaded > 0) or die "Uh oh, we somehow were not able to load ANY orfs in the Run.pm function load_multi_orfs. Sample ID was <$sample_id>. Maybe this is because you didn't --stage the database? Really unclear.";
}

sub bulk_load_orf{
    my $self    = shift;
    my $seqfile = shift;
    my $sid     = shift;
    my $method  = shift;
    my $tmp    = "/tmp/" . $sid . ".sql";	    
    my $table  = "orfs";
    my $nrows  = 10000;
    my @fields = ( "sample_id", "read_alt_id" );
    my $fks    = { "sample_id" => $sid,
		   "method" => $method,
                 }; 
    $self->Shotmap::DB::bulk_import( $table, $seqfile, $tmp, $nrows, $fks, \@fields );
    return $self;
}

sub read_alt_id_to_read_id{
    my $self        = shift;
    my $read_alt_id = shift;
    my $sample_id   = shift;
    my $read_map    = shift; #hashref
    my $read_id;
    if( defined( $read_map->{ $read_alt_id } ) ){
	$read_id = $read_map->{ $read_alt_id };
    }
    else{
	my $reads = $self->get_schema->resultset("Metaread")->search(
	    {
		read_alt_id => $read_alt_id,
		sample_id   => $sample_id,
	    }
	    );
	if( $reads->count() > 1 ){
	    warn "Found multiple reads that match read_alt_id: $read_alt_id and sample_id: $sample_id in load_orf. Cannot continue!\n";
	    die;
	}
	my $read = $reads->next();
	$read_id = $read->read_id();
    }
    return $read_id;
}

sub parse_orf_id{
    my $self   = shift;
    my $orfid  = shift;
    my $method = shift;
    my $read_id = ();
    if( $method eq "transeq" ){
	if( $orfid =~ m/^(.*?)\_\d$/ ){
	    $read_id = $1;
	}
	else{
	    die "Can't parse read_id from $orfid\n";
	}
    }
    if( $method eq "transeq_split" ){
	if( $orfid =~ m/^(.*?)\_\d_\d+$/ ){
	    $read_id = $1;
	}
	else{
	    die "Can't parse read_id from $orfid\n";
	}
    }
    return $read_id;
}

sub parse_and_load_search_results_bulk{
    my $self                = shift;
    my $sample_id           = shift;
    my $orf_split_filename  = shift; # just the file name of the split, NOT the full path
    my $class_id            = shift; #the classification_id
    my $algo                = shift;
    my $tophits_per_fam     = 0; #maybe we flush this out in future
    my $tophits_only        = 1;

    ($orf_split_filename !~ /\//) or die "The orf split FILENAME had a slash in it (it was \"$orf_split_filename\"). But this is only allowed to be a FILENAME, not a directory! Fix this programming error.\n";

    #remember, each orf_split has its own search_results sub directory
    my $search_results = File::Spec->catfile($self->get_sample_path($sample_id), "search_results", $algo, $orf_split_filename);
    my $query_seqs     = File::Spec->catfile($self->get_sample_path($sample_id), "orfs", $orf_split_filename);
    
    print "Grabbing results for sample ${sample_id} from ${search_results}\n";
    #open search results, get all results for this split
    opendir( RES, $search_results ) || die "Can't open $search_results for read in classify_reads: $!\n";
    my @result_files = readdir( RES );
    closedir( RES );
    my $split_results_cat = $search_results . ".mysqld.splitcat";
    my $orf_tophits = {};
    foreach my $result_file( @result_files ){
	next if( $result_file !~ m/\.mysqld/ ); #we only want to load the mysql data tables that we produced earlier
	if(not( $result_file =~ m/$orf_split_filename/ )) {
	    warn "Skipped the file $result_file, as it did not match the name: $orf_split_filename.";
	    next; ## skip it!
	}
	#we have to look across all result files in this dir and for each orf to fam mapping, grab the top scoring hit
	#only if we want expanded search result ouput. Probably rare
	if( $tophits_per_fam ){
	    $orf_tophits = find_orf_fam_tophit( "${search_results}/${result_file}", $orf_tophits );
	} elsif( $tophits_only ){
	    #we have to look across all result files in this dir and for each orf to fam mapping, grab the top scoring hit
	    $orf_tophits = find_orf_tophit( "${search_results}/${result_file}", $orf_tophits );
	}
	
#	File::Cat::cat( "${search_results}/${result_file}", $fh ); # From the docs: "Copies data from EXPR to FILEHANDLE, or returns false if an error occurred. EXPR can be either an open readable filehandle or a filename to use as input."	
    }
    my $fh;
    open( $fh, ">$split_results_cat" ) || die "Can't open $split_results_cat for write: $!\n";

    foreach my $orf( keys( %$orf_tophits ) ){      
	if( $tophits_per_fam ){
	    foreach my $fam( keys( %{ $orf_tophits->{$orf} } ) ){
		print $fh $orf_tophits->{$orf}->{$fam}->{'row'} . "\n";
	    }
	} elsif( $tophits_only ){
	    print $fh $orf_tophits->{$orf}->{'row'} . "\n";
	}
    }
    close $fh;
#    if( $self->is_slim && $self->bulk_load ){
    print "Loading results for sample ${sample_id} into database\n";
    if( 1 ){ #we REQUIRE this type lof loading now
	my $tmp    = "/tmp/" . $sample_id . ".sql";	    
	my $table  = "searchresults";
	my $nrows  = 10000;
	my @fields = ( "orf_alt_id", "read_alt_id", "sample_id", "target_id", "famid", "score", "evalue", "orf_coverage", "aln_length", "classification_id" );
	my $fks    = { "sample_id"         => $sample_id, 
		       "classification_id" => $class_id,
	};	   #do we need this? seems safer, and easier to insert, remove samples/classifications from table this way, but also a little slower with extra key check. those tables are small.
	$self->Shotmap::DB::bulk_import( $table, $split_results_cat, $tmp, $nrows, $fks, \@fields );    
    }
    #clean up
    close $fh;
#    unlink( $split_results_cat );
    return $self;
}

sub find_orf_tophit{ #for each orf to family mapping, find the top hit
    my( $result_file, $orf_tophit ) = @_;
    open( FILE, $result_file ) || die "Can't open $result_file for read: $!\n";
    while(<FILE>){
	chomp $_;
	my( $orf, $famid, $score );
	if( $_ =~ m/(.*?)\,(.*?)\,(.*?)\,(.*?)\,(.*?)\,(.*?)\,(.*?)\,(.*?)\,(.*?)/ ){
	    $orf    = $1;
	    $famid  = $5;
	    $score  = $6;
	} else {
	   warn( "Can't parse orf_alt_id, famid, or score from $result_file where line is $_\n" );
	   next;
	}
	if( !defined($orf_tophit->{$orf} ) ){
	    $orf_tophit->{$orf}->{'score'} = $score;
	    $orf_tophit->{$orf}->{'row'}   = $_;
	}
	elsif( $score > $orf_tophit->{$orf}->{'score'} ){
	    $orf_tophit->{$orf}->{'score'} = $score;
	    $orf_tophit->{$orf}->{'row'}   = $_;
	}
	else{
	    #do nothing. this is a poorer hit than what we already have
	}
    }
    close FILE;
    return $orf_tophit;
}

sub find_orf_fam_tophit{ #for each orf to family mapping, find the top hit
    my( $result_file, $orf_fam_tophit ) = @_;
    open( FILE, $result_file ) || die "Can't open $result_file for read: $!\n";
    while(<FILE>){
	chomp $_;
	my( $orf, $famid, $score );
	if( $_ =~ m/(.*?)\,(.*?)\,(.*?)\,(.*?)\,(.*?)\,(.*?)\,(.*?)\,(.*?)\,(.*?)/ ){
	    $orf    = $1;
	    $famid  = $5;
	    $score  = $6;
	} else {
	   warn( "Can't parse orf_alt_id, famid, or score from $result_file where line is $_\n" );
	   next;
	}
	if( !defined($orf_fam_tophit->{$orf}->{$famid} ) ){
	    $orf_fam_tophit->{$orf}->{$famid}->{'score'} = $score;
	    $orf_fam_tophit->{$orf}->{$famid}->{'row'}   = $_;
	}
	elsif( $score > $orf_fam_tophit->{$orf}->{$famid}->{'score'} ){
	    $orf_fam_tophit->{$orf}->{$famid}->{'score'} = $score;
	    $orf_fam_tophit->{$orf}->{$famid}->{'row'}   = $_;
	}
	else{
	    #do nothing. this is a poorer hit than what we already have
	}
    }
    close FILE;
    return $orf_fam_tophit;
}

sub _parse_famid_from_ffdb_seqid {
    my $hit = shift;
    my $famid;
    if( $hit =~ m/^(.*?)\_(\d+)$/ ){
	$famid = $2;
    }
    else{
	warn( "Can't parse famid from $hit in _parse_famid_from_ffdb_seqid!\n" );
	die;
    }
    return $famid;
}

sub build_search_db{
    my $self        = shift;
    my $db_name     = shift; #name of db to use, if build, new db will be named this. check for dups
    my $split_size  = shift; #integer - how many hmms per split?
    my $force       = shift; #0/1 - force overwrite of old DB during compression.
    my $type        = shift; #blast/hmm
    my $reps_only   = shift; #0/1 - should we only use representative sequences in our sequence DB
    my $nr_db       = shift; #0/1 - should we use a non-redundant version of the DB (sequence DB only)

    my $ffdb        = $self->ffdb();
    my $ref_ffdb    = $self->ref_ffdb();

    #where is the hmmdb going to go? each hmmdb has its own dir
    my $raw_db_path = undef;
    my $length      = 0;
    if ($type eq "hmm")   { $raw_db_path = $self->search_db_path("hmm"); }
    if ($type eq "blast") { $raw_db_path = $self->search_db_path("blast"); }

    warn "Building $type DB $db_name, placing $split_size per split\n";

    #Have you built this DB already?

    if( -d $raw_db_path && !($force) ){
	warn "You've already built a <$type> database with the name <$db_name> at <$raw_db_path>. Please delete or overwrite by using the --forcedb option.\n";
	exit(0);
    }

    #create the HMMdb dir that will hold our split hmmdbs
    $self->Shotmap::DB::build_db_ffdb( $raw_db_path );
    #update the path to make it easier to build the split hmmdbs (e.g., points to an incomplete file name)
    #save the raw path for the database_length file when using blast

    my $db_path_with_name     = "$raw_db_path/$db_name";
    #get the paths associated with each family
    my $family_path_hashref = _build_family_ref_path_hash( $ref_ffdb, $type );
    #constrain analysis to a set of families of interest
    my @families   = sort( @{ $self->family_subset() });
    if( !@families ){ #is there a subset list? No? then process EVERY family
	@families = keys( %{ $family_path_hashref->{$type} } );
    }
    my $n_fams = @families;
    my $count      = 0;
    my @split      = (); #array of family HMMs/sequences (compressed)
    my $n_proc     = 0;
    #type eq blast specific vars follow
    my $tmp;
    my $tmp_path;
    my $total = 0;
    my $seqs  = {};
    my $id    = ();
    my $seq   = '';	   
    my $redunts;
    #build a map of family lengths
    open( FAMLENS, ">${raw_db_path}/family_lengths.tab" ) || die "Can't open ${raw_db_path}/family_lengths.tab for write: $!\n";
    #build a map of family member sequence lengths, not relevant for type = hmm
    open( SEQLENS, ">${raw_db_path}/sequence_lengths.tab" ) || die "Can't open ${raw_db_path}/sequence_lengths.tab for write:$!\n";
    #blast requires tmp files for creation of NR database
    if( $type eq "blast" ){
	$tmp_path = "${db_path_with_name}.tmp";
	open( TMP, ">$tmp_path" ) || die "Can't open $tmp_path for write: $!\n";
	$tmp = *TMP;	    
	#need a home to list redundant sequence mappings if $nr_db
	if( $nr_db ){
	    my $redunt_path = "${raw_db_path}/redundant_sequence_pairings.tab";
	    open( REDUNTS, ">${redunt_path}" ) || die "Can't open ${redunt_path} for write:$!\n";
	    $redunts = *REDUNTS;
	}
    }       
    foreach my $family( @families ){
	#find the HMM/sequences associated with the family (compressed)
	my $family_db_file = undef;
	my $family_length  = undef;
	if ($type eq "hmm") {
#	    my $path = "${ref_ffdb}/HMMs/${family}.hmm.gz";
	    my $path = $family_path_hashref->{$type}->{$family};
	    if( -e $path ) { $family_db_file = $path; } # assign the family_db_file to this path ONLY IF IT EXISTS!
	    $family_length = _get_family_length( $family_db_file, $type ); #get the family length from the HMM file
	    print FAMLENS join( "\t", $family, $family_length, "\n" );
	    (defined($family_db_file)) or die("Can't find the HMM corresponding to family $family\n" );
	    push( @split, $family_db_file );
	    $count++;
	    #if we've hit our split size, process the split
	    if($count >= $split_size || $family == $families[-1]) {
		$n_proc++; 	    #build the DB
		my $split_db_path;
		if( $type eq "hmm" ){
		    $split_db_path = Shotmap::Run::cat_db_split($db_path_with_name, $n_proc, $ffdb, ".hmm", \@split, $type, 0); # note: the $nr_db parameter for hmm is ALWAYS zero --- it makes no sense to build a NR HMM DB
		} 
		gzip_file($split_db_path); # We want DBs to be gzipped.
		unlink($split_db_path); # So we save the gzipped copy, and DELETE the uncompressed copy
		@split = (); # clear this out
		$count = 0; # clear this too
	    }
	} elsif( $type eq "blast" ) {
#	    my $path = "$ref_ffdb/seqs/${family}.fa.gz";
	    my $path = $family_path_hashref->{$type}->{$family};	    
	    if( -e $path ){
		$family_db_file = $path; # <-- save the path, if it exists
		if ($reps_only) {
		    #do we only want rep sequences from big families?
		    #first see if there is a reps file for the family
		    my $reps_seq_path = $path;
		    $reps_seq_path    =~ s/seqs_all/seqs_reps/;
		    $family_db_file   = $reps_seq_path;
		    #if so, see if we need to build the seq file
		    #OBSOLETE
		    if( 0 ){
			my $reps_list_path = "${ref_ffdb}/reps/list/${family}.mcl";
			if( -e $reps_seq_path ){
			    #we add the .gz extension in the gzip command inside grab_seqs_from_lookup_list
			    if(! -e "${reps_seq_path}.gz" ){
				print "Building reps sequence file for $family\n";
				_grab_seqs_from_lookup_list( $reps_list_path, $family_db_file, $reps_seq_path );
				(-e "${reps_seq_path}.gz") or 
				    die("The gzipped file STILL doesn't exist, even after we tried to make it. Error grabbing " .
					"representative sequences from $reps_list_path. Trying to place in $reps_seq_path.");
			    }
			    $family_db_file = "${reps_seq_path}.gz"; #add the .gz path because of the compression we use in grab_seqs_from_loookup_list
			}
		    }
		}
	    }
	    (defined($family_db_file)) or die( "Can't find the BLAST database corresponding to family $family\n" );
	    #process the families and produce split dbs along the way
	    my $compressed = 0; #auto detect if ref-ffdb family files are compressed or not
	    if( $family_db_file =~ m/\.gz$/ ){
		$compressed = 1;
	    }
	    my $suffix = ''; #determine the suffix of the family file
	    if( $family_db_file =~ m/\.faa$/ || $family_db_file =~ /\.faa\.gz$/ ){
		$suffix = ".faa";
	    } elsif( $family_db_file =~ m/\.fa$/ || $family_db_file =~ /\.fa\.gz$/ ){
		$suffix = ".fa";
	    } else {
		die ("I could not determine the suffix associated with $family_db_file\n" );
	    }	   
	    if( $nr_db ){				
		my $nr_tmp      = _build_nr_seq_db( $family_db_file, $suffix, $compressed, $redunts );
		$family_db_file = $nr_tmp;
	    }
	    open( FILE, "zcat --force $family_db_file |") || die "Unable to open the file \"$family_db_file\" for reading: $! --"; # zcat --force can TRANSPARENTLY read both .gz and non-gzipped files!
	    my $fam_init_len = $length; #used to calculate $family_length
	    my $fam_nseqs    = 0; #used to calculate $family_length	    
	    my $seq_len      = 0;
	    while(<FILE>){
		if ( $_ =~ m/^\>/ ){ 
		    $total++;
		    $fam_nseqs++;
		    #no longer need _append_famids_to_seqids, we just do it here now
		    chomp $_;
		    if( defined( $id ) ){ #then we've seen a seq before, add that one to the hash
			$seqs->{$id} = $seq; #build an amended id to sequence hash for batch printing (below)
			$id =~ s/\>//; #get rid of fasta header indicator for our SEQLENS lookup map
			chomp( $id );
			print SEQLENS join( "\t", $family, $id, $seq_len, "\n" );
			$id  = ();
			$seq = '';
			$seq_len = 0;
		    }
		    $id = $_ . "_" . $family . "\n"; #note that this may break families that have more than seqid on the header line
		} else{
		    chomp $_; # remove the newline
		    $length += length($_);
		    $seq    .= $_ . "\n";
		    $seq_len += length($_);
		}
		if( eof ){ #end of file could be the current line or the next line (empty), so separate it from the main conditional statement
		    $seqs->{$id} = $seq; #build an amended id to sequence hash for batch printing (below)
		    $id =~ s/\>//; #get rid of fasta header indicator for our SEQLENS lookup map
		    chomp( $id );
		    print SEQLENS join( "\t", $family, $id, $seq_len, "\n" );
		    $id  = ();
		    $seq = '';
		    $seq_len = 0;		
		}
		#we've hit our desired size (or at the end). Process the split
		if( ( scalar( keys( %$seqs ) ) >= $split_size ) || ( $family eq $families[-1] && eof )) {
		    foreach my $id( keys( %$seqs ) ){
			print $tmp $id;
			print $tmp $seqs->{$id};
		    }
		    close $tmp;
		    $n_proc++; 	    #build the db split number
		    my $split_db_path = "${db_path_with_name}_${n_proc}.fa";
		    move( $tmp_path, $split_db_path );		    
		    gzip_file($split_db_path); # We want DBs to be gzipped.
		    unlink($split_db_path); # So we save the gzipped copy, and DELETE the uncompressed copy
		    $seqs = {};
		    unless( $family == $families[-1] && eof ){
			open( TMP, ">${db_path_with_name}.tmp" ) || die "Can't open ${db_path_with_name}.tmp for write: $!\n";
			$tmp = *TMP;	    
		    }
		}
	    }
	    close FILE;
	    if( $nr_db ){
		#we don't want to keep the copy of the tmp nr file that we created, which was pushed into $family_db_file above
		unlink( $family_db_file );
	    }
	    #calculate the family's length
	    $family_length = ( $length - $fam_init_len ) / $fam_nseqs; #average length of total sequence found in family
	    if( defined( $family_length ) ){
		print FAMLENS join( "\t", $family, $family_length, $fam_nseqs, "\n" );
	    } else {
		die "Cannot calculate a family length for $family\n";
	    }       	    
	}
	else { 
	    die "invalid type: <$type>"; 
	}
    }
    close FAMLENS;
    close SEQLENS;
    if( $nr_db ){
	close $redunts;
    }
    #print out the database length
    open( LEN, ">${raw_db_path}/database_length.txt" ) || die "Can't open ${raw_db_path}/database_length.txt for write: $!\n";
    print LEN $length;
    close LEN;

    print STDERR "Build Search DB: $type DB was successfully built and compressed.\n";
}

sub _get_family_length{
    my ( $family_db_file, $type ) = @_;
    my $family_length;
    if( $type eq "hmm" ){
	open( FILE, "zcat --force $family_db_file |") || die "Unable to open the file \"$family_db_file\" for reading: $! --"; # zcat --force can TRANSPARENTLY read both .gz and non-gzipped files!
	while(<FILE>){
	    chomp $_;
	    if( $_ =~ m/LENG\s+(\d+)/){
		$family_length = $1;
		last;
	    }
	}
    } elsif( $type eq "blast" ){
	#we calculate length in build_search_db since we open files there anyhow
    }
    else{
	die "Passed an unknown type to _get_family_length (received ${type})\n";
    }    
    return $family_length;
}

#this recurses through all subdirs under ref-ffdb to look for the seqs and hmms of interest. Be careful with how
#ref-ffdb is structured!
sub _build_family_ref_path_hash{ 
    my ( $ref_ffdb, $type ) = @_;
    #open the ref_ffdb and look for family-related files (hmms and seqs)
    my $family_paths = {};
    my $recurse_lvl = 1; #we use these two vars to limit the number of dirs we look into. Otherwise, code can get lost.
    my $recurse_lim = 3; 
    $family_paths = _get_family_path_from_dir( $ref_ffdb, $type, $recurse_lvl, $recurse_lim, $family_paths ); 
    return $family_paths; #a hashref
}

sub _get_family_path_from_dir{
    my $dir = shift;
    my $type = shift;
    my $recurse_lvl  = shift; #how many recursions are we on
    my $recurse_lim  = shift; #how many total recursions do we allow?
    my $family_paths = shift; #hashref
    opendir( DIR, $dir ) || die "Can't opendir on $dir\n";
#    my @paths = glob( "${path}/*" );
    my @paths = readdir( DIR );
    closedir DIR;
    foreach my $p( @paths ){ #top level must be dirs. will skip any files here
	next if ( $p =~ m/^\./ );
	my $path = $dir . "/" . $p;
	next unless( -d "${path}" );
	#are the top level dirs what we're looking for?
	#print "Looking in $path\n";
	if( $path =~ m/hmms_full$/ ){
	    if( $type eq "hmm" ){ #find hmms and build the db		
		print "Grabbing family paths from $path\n";
		opendir( SUBDIR, $path ) || die "Can't opendir subdir $path: $!\n";
		my @files = readdir( SUBDIR );
		closedir SUBDIR;
		foreach my $file( @files ){
		    next if ($file =~ m/tmp/ ); #don't want to grab any tmp files from old, failed run
		    next unless( $file =~ m/(.*)\.hmm/ );
		    my $family = $1;
		    my $hmm_path = "${path}/${family}.hmm";
		    $family_paths->{$type}->{$family} = $hmm_path;
		}
	    }
	}
	elsif( $path =~ m/seqs_all$/ ){ #then this dir contains seqs that we want to process
	    if( $type eq "blast" ){ #find the seqs and build the db
		print "Grabbing family paths from $path\n";
		opendir( SUBDIR, $path ) || die "Can't opendir subdir $path: $!\n";
		my @files = readdir( SUBDIR );
		closedir SUBDIR;
		foreach my $file( @files ){
		    next if ($file =~ m/tmp/ ); #don't want to grab any tmp files from old, failed run
		    next unless( $file =~ m/(.*)\.fa/ || $file =~ m/(.*)\.faa/ );
		    my $family = $1;
		    my $seq_path = "${path}/${file}";
		    $family_paths->{$type}->{$family} = $seq_path;
		}		
	    }  
	}
	else{ #don't have what we're looking for in the top level dirs, so let's recurse a level
	    my $sub_recurse_lvl = $recurse_lvl + 1; #do this so that each of the sister subdirs get processed fairly
	    if( $sub_recurse_lvl >= $recurse_lim ){
		#print "Won't go into $path because recursion limit hit. Recursion number is $sub_recurse_lvl\n";
		next;
	    }
	    $family_paths = _get_family_path_from_dir( $path, $type, $sub_recurse_lvl, $recurse_lim, $family_paths ); 
	}
    }
    return $family_paths;
}

sub cat_db_split{
    my ($db_path, $n_proc, $ffdb, $suffix, $ra_families_array_ptr, $type, $nr_db) = @_;
    my @families     = @{$ra_families_array_ptr}; # ra_families is a POINTER TO AN ARRAY
    my $split_db_path = "${db_path}_${n_proc}${suffix}";
    my $fh;
    open( $fh, ">> $split_db_path" ) || die "Can't open $split_db_path for write: $!\n";
    foreach my $family( @families ){
	my $compressed = 0; #auto detect if ref-ffdb family files are compressed or not
	if( $family =~ m/\.gz$/ ){
	    $compressed = 1;
	}
	#do we want a nonredundant version of the DB? OBSOLETE. DO THIS VIA build_search_db now
	if( $type eq "blast" && defined($nr_db) && $nr_db ){
	    #make a temp file for the nr 
	    #append famids to seqids within this routine
	    my $tmp = _build_nr_seq_db( $family, $suffix, $compressed ); #make a tmp file for the nr
	    File::Cat::cat( $tmp, $fh ); # From the docs: "Copies data from EXPR to FILEHANDLE, or returns false if an error occurred. EXPR can be either an open readable filehandle or a filename to use as input."
	    unlink( $tmp ); #delete the tmp file
	}
	#append famids to seqids, don't build NR database
	elsif( $type eq "blast" ){
	    my $tmp = _append_famids_to_seqids( $family, $suffix, $compressed );
	    File::Cat::cat( $tmp, $fh );
	    unlink( $tmp );
	}
	else{
	    if( $compressed ){
		gunzip $family => $fh;
	    }
	    else{
		File::Cat::cat( $family, $fh );
	    }
	}
    }
    close $fh;
    return $split_db_path;
}

sub _append_famids_to_seqids{
    my $family = shift;
    my $suffix = shift;
    my $compressed = shift;
    my $family_tmp = $family . "_tmp";
    my( $seqin );
    if( $compressed ){
	$seqin  = Bio::SeqIO->new( -file => "zcat $family |", -format => 'fasta' );
    } else {
	$seqin  = Bio::SeqIO->new( -file => "$family", -format => 'fasta' );
    }
    my $seqout = Bio::SeqIO->new( -file => ">$family_tmp", -format => 'fasta' );
    my $dict   = {};
    my $famid =  _get_famid_from_familydb_path( $family, $suffix, $compressed );
    while( my $seq = $seqin->next_seq ){
	my $id       = $seq->display_id();
	$seq->display_id( $id . "_" . $famid );
	$seqout->write_seq( $seq );
    }    
    return $family_tmp;    
}

#Note heuristic here: builiding an NR version of each family_db rather than across the complete DB. 
#Assumes identical sequences are in same family, decreases RAM requirement. First copy of seq is retained
#can speed this up by getting out of bioperl if necessary....
sub _build_nr_seq_db{
    my $family    = shift;
    my $suffix    = shift;
    my $compressed = shift;
    my $dups_list_file = shift;
    my $family_nr  = $family . "_nr_tmp";
    my $seqin;
    if( $compressed ){
	$seqin   = Bio::SeqIO->new( -file => "zcat $family |", -format => 'fasta' );
    } else {
	$seqin   = Bio::SeqIO->new( -file => "$family", -format => 'fasta' );
    }
    my $seqout  = Bio::SeqIO->new( -file => ">$family_nr", -format => 'fasta' );
    my $dict    = {};
    my $famid   =  _get_famid_from_familydb_path( $family, $suffix );
    my $baseid  = basename( $family, $suffix );
    while( my $seq = $seqin->next_seq ){
	my $id       = $seq->display_id();
#	$seq->display_id( $id . "_" . $famid ); We append earlier now with _append_famids_to_seqids
	$seq->display_id( $id );
	my $sequence = $seq->seq();
	#if we haven't seen this seq before, print it out
	if( !defined( $dict->{$sequence} ) ){
	    $seqout->write_seq( $seq );
	    $dict->{$sequence} = $id;
	} else { #print out the duplicate sequence pairings
	    if( defined( $dups_list_file ) ){
		my $retained_id = $dict->{$sequence};
		print $dups_list_file join( "\t", $family, $retained_id, $id, "\n" );
	    }
	}
    }    
    my $gzip_nr = $family_nr . ".gz";
    gzip $family_nr => $gzip_nr || die "gzip failed for $family_nr: $GzipError\n";
    return $family_nr;
}

#i'm worried that this might break any families that are not formatted ala SFam famids (e.g., Pfam ids)
sub _get_famid_from_familydb_path{
    my $path = shift;
    my $suffix = shift;
    my $compressed;
    if( $compressed ){
	$suffix    = $suffix . ".gz";
    }
    my $famid  = basename( $path, $suffix );
    return $famid;
}

sub _grab_seqs_from_lookup_list{
    my $seq_id_list = shift; #list of sequence ids to retain
    my $seq_file    = shift; #compressed sequence file
    my $out_seqs    = shift; #compressed retained sequences

    my $lookup      = {}; # apparently this is a hash pointer? or list or something? It isn't a "%" variable for some reason.
    print "Selecting reps from $seq_file, using $seq_id_list. Results in $out_seqs\n";
    #build lookup hash
    open( LOOK, $seq_id_list ) || die "Can't open $seq_id_list for read: $!\n";
    while(<LOOK>){
	chomp $_;
	$lookup->{$_}++;
    }
    close LOOK;
    my $seqs_in  = Bio::SeqIO->new( -file => "zcat $seq_file |", -format => 'fasta' );
    my $seqs_out = Bio::SeqIO->new( -file => ">$out_seqs", -format => 'fasta' );
    while(my $seq = $seqs_in->next_seq()){
	my $id = $seq->display_id();
	if( defined( $lookup->{$id} ) ){
	    $seqs_out->write_seq( $seq );
	}
    }
    gzip_file( $out_seqs );    
    unlink( $out_seqs );
}

#calculates total amount of sequence in a file (looks like actually in a DIRECTORY rather than a file)
sub calculate_blast_db_length{
    my ($self) = @_;

    (defined($self->search_db_name("blast"))) or die "dbname was not already defined! This is a fatal error.";
    (defined($self->ffdb())) or die "ffdb was not already defined! This is a fatal error.";

    my $db_path = File::Spec->catdir($self->ffdb(), $BLASTDB_DIR, $self->search_db_name("blast"));
    opendir( DIR, $db_path ) || die "Can't opendir $db_path for read: $! ";
    my @files = readdir(DIR);
    closedir DIR;
    my $numFilesRead = 0;

    my $PRINT_OUTPUT_EVERY_THIS_MANY_FILES = 25;
    my $lenTotal  = 0;
    foreach my $file (@files) {
	next unless( $file =~ m/\.fa/ ); # ONLY include files ending in .fa
	my $lengthThisFileOnly = get_sequence_length_from_file(File::Spec->catfile($db_path, $file));
	$lenTotal += $lengthThisFileOnly;
	$numFilesRead++;
	if ($numFilesRead == 1 or ($numFilesRead % $PRINT_OUTPUT_EVERY_THIS_MANY_FILES == 0)) {
	    # Print diagnostic data for the FIRST entry, as well as periodically, every so often.
	    $self->Shotmap::Notify::notify("[$numFilesRead/" . scalar(@files) . "]: Got a sequence length of $lengthThisFileOnly from <$file>. Total length: $lenTotal");
	}
    }
    $self->Shotmap::Notify::notify("$numFilesRead files were read. Total sequence length was: $lenTotal");
    return $lenTotal;
}

sub compress_hmmdb{
    my ($file, $force) = @_;
    my @args = ($force) ? ("-f", "$file") : ("$file"); # if we have FORCE on, then add "-f" to the options for hmmpress
    warn "I hope 'hmmpress' is installed on this machine already!";
    my $results  = IPC::System::Simple::capture( "hmmpress " . "@args" );
    (0 == $EXITVAL) or die("Error translating sequences in $file: $results ");
    return $results;
}

#copy a project's ffdb over to the remote server
sub load_project_remote {
    my ($self) = @_;
    my $project_dir_local = File::Spec->catdir($self->ffdb(), "projects", $self->db_name(), $self->project_id());
    my $remote_dir  = $self->remote_connection() . ":" . File::Spec->catdir($self->remote_ffdb(), "projects", $self->db_name(),  $self->project_id());
    warn("Pushing $project_dir_local to the remote (" . $self->remote_host() . ") server's ffdb location in <$remote_dir>\n");
    my $results = $self->Shotmap::Run::transfer_directory($project_dir_local, $remote_dir);
    return $results;
}

#the qsub -sync y option keeps the connection open. lower chance of a connection failure due to a ping flood, but if connection between
#local and remote tends to drop, this may not be foolproof
sub translate_reads_remote($$$$$) {
    my ($self, $waitTimeInSeconds, $logsdir, $should_we_split_orfs, $filter_length) = @_;
    ($should_we_split_orfs == 1 or $should_we_split_orfs == 0) or die "Split orf setting should either be 1 or 0! Other values NOT ALLOWED. Even 'undef' is not allowed. Fix this programming error. The value was: <$should_we_split_orfs>.";
    #push translation scripts to remote server
    my $connection = $self->remote_connection();
    my $remote_script_dir = $self->remote_scripts_dir();

    my $local_copy_of_remote_handler  = File::Spec->catfile($self->local_scripts_dir(), "remote", "run_transeq_handler.pl");
    my $local_copy_of_remote_script   = File::Spec->catfile($self->local_scripts_dir(), "remote", "run_transeq_array.sh"); 
    my $transeqPerlRemote = File::Spec->catfile($remote_script_dir, "run_transeq_handler.pl");
    
    $self->Shotmap::Run::transfer_file_into_directory($local_copy_of_remote_handler, "$connection:$remote_script_dir/"); # transfer the script into the remote directory
    $self->Shotmap::Run::transfer_file_into_directory($local_copy_of_remote_script,  "$connection:$remote_script_dir/"); # transfer the script into the remote directory

    warn "About to translate reads...";

    my @scriptsToTransfer = (File::Spec->catfile($self->local_scripts_dir(), "remote", "split_orf_on_stops.pl"));
    foreach my $transferMe (@scriptsToTransfer) {
	$self->Shotmap::Run::transfer_file_into_directory($transferMe, $self->remote_connection() . ':' . $self->remote_scripts_dir() . '/'); # transfer the script into the remote directory
    }

    my $numReadsTranslated = 0;
    foreach my $sample_id( @{$self->get_sample_ids()} ) {
	my $remote_raw_dir    = File::Spec->catdir($self->remote_ffdb(), "projects", $self->db_name, $self->project_id(), $sample_id, "raw");
	my $remote_output_dir = File::Spec->catdir($self->remote_ffdb(), "projects", $self->db_name, $self->project_id(), $sample_id, "orfs");
	$self->Shotmap::Notify::notify("Translating reads on the REMOTE machine, from $remote_raw_dir to $remote_output_dir...");
	if ($should_we_split_orfs) {
	    # Split the ORFs!
	    my $local_unsplit_dir  =        $self->ffdb() . "/projects/" . $self->db_name . "/" . $self->project_id() . "/$sample_id/unsplit_orfs"; # This is where the files will be tranferred BACK to. Should NOT end in a slash!
	    my $remote_unsplit_dir = $self->remote_ffdb() . "/projects/" . $self->db_name . "/" .  $self->project_id() . "/$sample_id/unsplit_orfs"; # Should NOT end in a slash!
	    my $remote_cmd = "\'" . "perl ${transeqPerlRemote} " . " -i $remote_raw_dir" . " -o $remote_output_dir" . " -w $waitTimeInSeconds" . " -l $logsdir" . " -s $remote_script_dir" . " -u $remote_unsplit_dir" . " -f $filter_length" . "\'";
	    my $response = $self->Shotmap::Run::execute_ssh_cmd($connection, $remote_cmd);
	    $self->Shotmap::Notify::notify("Translation result text, if any was: \"$response\"");
	    $self->Shotmap::Notify::notify("Translation complete, Transferring split and raw translated orfs\n");
	    $self->Shotmap::Run::transfer_directory("${connection}:$remote_unsplit_dir", $local_unsplit_dir); # REMOTE to LOCAL: the unsplit orfs
	} else{
	    my $remote_cmd_no_unsplit = "\'perl ${transeqPerlRemote} " . " -i $remote_raw_dir" . " -o $remote_output_dir" . " -w $waitTimeInSeconds" . " -l $logsdir" . " -s $remote_script_dir" . "\'";
	    $self->Shotmap::Run::execute_ssh_cmd($connection, $remote_cmd_no_unsplit);
	}

	$self->Shotmap::Notify::notify("Translation complete, Transferring ORFs\n");
	
	my $theOutput = $self->Shotmap::Run::execute_ssh_cmd($connection, "ls -l $remote_output_dir/");
	$self->Shotmap::Notify::notify("Got the following files that were generated on the remote machine:\n$theOutput");
	(not($theOutput =~ /total 0/i)) or die "Dang! Somehow nothing was translated on the remote machine. We expected the directory \"$remote_output_dir\" on the machine " . $self->remote_host() . " to have files in it, but it was totally empty! This means the translation of reads probably failed. You had better check the logs on the remote machine! There is probably something interesting in the \"" . File::Spec->catdir($logsdir, "transeq") . "\" directory (on the REMOTE machine!) that will tell you exactly why this command failed! Check that directory!";

	my $localOrfDir  = File::Spec->catdir($self->get_sample_path($sample_id), "orfs");
	$self->Shotmap::Run::transfer_directory("$connection:$remote_output_dir", $localOrfDir); # This happens in both cases, whether or not the orfs are split!
	$numReadsTranslated++;
    }
    $self->Shotmap::Notify::notify("All reads were translated on the remote server and locally acquired. Total number of translated reads: $numReadsTranslated");
    ($numReadsTranslated > 0) or die "Uh oh, the number of reads translated was ZERO! This probably indicates a serious problem.";
}

sub job_listener($$$$) {
    # Note that this function is a nearly exact copy of "local_job_listener"
    my ($self, $jobsArrayRef, $waitTimeInSeconds, $is_remote) = @_;
    ($waitTimeInSeconds >= 1) or die "Programming error: You can't set waitTimeInSeconds to less than 1 (but it was set to $waitTimeInSeconds)---we don't want to flood the machine with constant system requests.";
    my %statusHash             = ();
    my $startTimeInSeconds = time();
    ($is_remote == 0 or $is_remote == 1) or die "is_remote must be 0 or 1! you passed in <$is_remote>.";
    while (scalar(keys(%statusHash)) != scalar(@{$jobsArrayRef})) { # keep checking until EVERY SINGLE job has a finished status
	#call qstat and grab the output
	my $results = undef;
	if ($is_remote) {
	    $results = $self->Shotmap::Run::execute_ssh_cmd( $self->remote_connection(), "\'qstat\'"); # REMOTE.
	} else { 
	    $results = IPC::System::Simple::capture("ps"); #call ps and grab the output. LOCAL.
	}
	#see if any of the jobs are complete. pass on those we've already finished
	foreach my $jobid( @{ $jobsArrayRef } ){
	    next if( exists( $statusHash{$jobid} ) );
	    if( $results !~ m/$jobid/ ){
		$statusHash{$jobid}++;
	    }
	}
	sleep($waitTimeInSeconds);
    }
    return (time() - $startTimeInSeconds); # return amount of wall-clock time this took
}

sub remote_job_listener{
    my ($self, $jobsArrayRef, $waitTimeInSeconds) = @_;
    return($self->job_listener($jobsArrayRef, $waitTimeInSeconds, 1));
}

sub local_job_listener{
    my ($self, $jobsArrayRef, $waitTimeInSeconds) = @_;
    return($self->job_listener($jobsArrayRef, $waitTimeInSeconds, 0));
}

sub remote_transfer_search_db{
    my ($self, $db_name, $type) = @_;
    my $DATABASE_PARENT_DIR = undef;
    if ($type eq "hmm")   { $DATABASE_PARENT_DIR = $HMMDB_DIR; }
    if ($type eq "blast") { $DATABASE_PARENT_DIR = $BLASTDB_DIR; }
    (defined($DATABASE_PARENT_DIR)) or die "Programming error: the 'type' in remote_transfer_search_db must be either \"hmm\" or \"blast\". Instead, it was: \"$type\". Fix this in the code!\n";
    my $db_dir     = $self->ffdb() . "/${DATABASE_PARENT_DIR}/${db_name}";
    my $remote_dir = $self->remote_connection() . ":" . $self->remote_ffdb() . "/$DATABASE_PARENT_DIR/$db_name";
    return($self->Shotmap::Run::transfer_directory($db_dir, $remote_dir));
}

sub remote_transfer_batch { # transfers HMMbatches, not actually a general purpose "batch transfer"
    my ($self, $hmmdb_name) = @_;
    my $hmmdb_dir   = $self->ffdb() . "/HMMbatches/$hmmdb_name";
    my $remote_dir  = $self->remote_connection() . ":" . $self->remote_ffdb() . "/HMMbatches/$hmmdb_name";
    return($self->Shotmap::Run::transfer_directory($hmmdb_dir, $remote_dir));
}

sub gunzip_file_remote {
    my ($self, $remote_file) = @_;
    my $remote_cmd = "gunzip -f $remote_file";
    return($self->Shotmap::Run::execute_ssh_cmd( $self->remote_connection(), $remote_cmd ));
}

sub gunzip_remote_dbs{
    my( $self, $db_name, $type ) = @_;    
    my $ffdb   = $self->ffdb();
    my $db_dir = undef;
    if ($type eq "hmm")      { $db_dir = "$ffdb/$HMMDB_DIR/$db_name"; }
    elsif ($type eq "blast") { $db_dir = "$ffdb/$BLASTDB_DIR/$db_name"; }
    else                     { die "invalid or unrecognized type."; }

    opendir( DIR, $db_dir ) || die "Can't opendir $db_dir for read: $!";
    my @files = readdir( DIR );
    closedir DIR;
    foreach my $file( @files ){
	next unless( $file =~ m/\.gz/ ); # Skip any files that are NOT .gz files
	my $remote_db_file;
	if( $type eq "hmm" ){   $remote_db_file = $self->remote_ffdb() . "/$HMMDB_DIR/$db_name/$file"; }
	if( $type eq "blast" ){ $remote_db_file = $self->remote_ffdb() . "/$BLASTDB_DIR/$db_name/$file"; }
	$self->Shotmap::Run::gunzip_file_remote($remote_db_file);
    }
}

sub format_remote_blast_dbs{
    my($self, $remote_script_path) = @_;
    my $remote_database_dir   = File::Spec->catdir($self->remote_ffdb(), $BLASTDB_DIR, $self->search_db_name("blast"));
    my $results               = $self->Shotmap::Run::execute_ssh_cmd($self->remote_connection(), "qsub -sync y $remote_script_path $remote_database_dir");
}

sub run_search_remote {
    my ($self, $sample_id, $type, $nsplits, $waitTimeInSeconds, $verbose, $forcesearch) = @_;
    ($type eq "blast" or $type eq "last" or $type eq "rapsearch" or $type eq "hmmsearch" or $type eq "hmmscan") or
	die "Invalid type passed in! The invalid type was: \"$type\".";
    ( $nsplits > 0 ) || die "Didn't get a properly formatted count for the number of search DB splits! I got $nsplits.";
    my $remote_orf_dir             = File::Spec->catdir(  $self->remote_sample_path($sample_id), "orfs");
    my $log_file_prefix            = File::Spec->catfile( $self->remote_project_log_dir(),       "${type}_handler");
    my $remote_results_output_dir  = File::Spec->catdir(  $self->remote_sample_path($sample_id), "search_results", ${type});
    my ($remote_script_path, $db_name, $remote_db_dir);

    if (($type eq "blast") or ($type eq "last") or ($type eq "rapsearch")) {
	$db_name               = $self->search_db_name("blast");
	$remote_db_dir         = File::Spec->catdir($self->remote_ffdb(), $BLASTDB_DIR, $db_name);
	if ($type eq "last" )     { $remote_script_path  = $self->remote_script_path("last");  } # LAST
	if ($type eq "blast")     { $remote_script_path  = $self->remote_script_path("blast"); } # BLAST
	if ($type eq "rapsearch") { $remote_script_path  = $self->remote_script_path("rapsearch"); } # BLAST
    }
    if (($type eq "hmmsearch") or ($type eq "hmmscan")) {
	$db_name               = $self->search_db_name("hmm");
	$remote_db_dir         = File::Spec->catdir($self->remote_ffdb(), $HMMDB_DIR, $db_name);
	if ($type eq "hmmsearch") { $remote_script_path = $self->remote_script_path("hmmsearch"); } # HMM *SEARCH*
	if ($type eq "hmmscan")   { $remote_script_path = $self->remote_script_path("hmmscan");   } # HMM *SCAN*
    }

    # Transfer the required scripts, such as "run_remote_search_handler.pl", to the remote server. For some reason, these don't get sent over otherwise!
    my @scriptsToTransfer = (File::Spec->catfile($self->local_scripts_dir(), "remote", "run_remote_search_handler.pl")); # just one file for now
    foreach my $transferMe (@scriptsToTransfer) {
	$self->Shotmap::Run::transfer_file_into_directory($transferMe, ($self->remote_connection() . ':' . $self->remote_scripts_dir() . '/')); # transfer the script into the remote directory
    }
    
    # See "run_remote_search" in run_remote_search_handler.pl
    my $remote_cmd  = "\'" . "perl " . File::Spec->catfile($self->remote_scripts_dir(), "run_remote_search_handler.pl")
	. " --resultdir=$remote_results_output_dir "
	. " --dbdir=$remote_db_dir "
	. " --querydir=$remote_orf_dir "
	. " --dbname=$db_name "
	. " --nsplits=$nsplits "
	. " --scriptpath=${remote_script_path} "
	. " -w $waitTimeInSeconds ";
    if( $forcesearch ){
	$remote_cmd .= " --forcesearch ";
    }
    $remote_cmd .=    "> ${log_file_prefix}.out 2> ${log_file_prefix}.err "
	. "\'"; # single quotes bracket this command for whatever reason

    my $results     = $self->Shotmap::Run::execute_ssh_cmd($self->remote_connection(), $remote_cmd, $verbose);
    (0 == $EXITVAL) or warn("Execution of command <$remote_cmd> returned non-zero exit code $EXITVAL. The remote reponse was: $results.");
    return $results;
}

sub parse_results_remote {
    my ($self, $sample_id, $type, $nsplits, $waitTimeInSeconds, $verbose, $forceparse) = @_;
    ($type eq "blast" or $type eq "last" or $type eq "rapsearch" or $type eq "hmmsearch" or $type eq "hmmscan") or
	die "Invalid type passed in! The invalid type was: \"$type\".";
    ( $nsplits > 0 ) || die "Didn't get a properly formatted count for the number of search DB splits! I got $nsplits.";
    my $trans_method = $self->trans_method;
    my $proj_dir     = $self->remote_project_path;
    my $scripts_dir  = $self->remote_scripts_dir;
    my $t_score      = $self->parse_score;
    my $t_coverage   = $self->parse_coverage;
    my $t_evalue     = $self->parse_evalue;
    my $remote_orf_dir             = File::Spec->catdir($self->remote_sample_path($sample_id), "orfs");
    my $log_file_prefix            = File::Spec->catfile($self->remote_project_log_dir(), "run_remote_parse_results_handler");
    my $remote_results_output_dir  = File::Spec->catdir($self->remote_sample_path($sample_id), "search_results", ${type});
    my ($remote_script_path, $db_name, $remote_db_dir);
    $remote_script_path        = $self->remote_scripts_dir() . "/run_parse_results.sh";
    if (($type eq "blast") or ($type eq "last") or ($type eq "rapsearch")) {
	$db_name               = $self->search_db_name("blast");
	$remote_db_dir         = File::Spec->catdir($self->remote_ffdb(), $BLASTDB_DIR, $db_name);
    }
    if (($type eq "hmmsearch") or ($type eq "hmmscan")) {
	$db_name               = $self->search_db_name("hmm");
	$remote_db_dir         = File::Spec->catdir($self->remote_ffdb(), $HMMDB_DIR, $db_name);
    }

    # Transfer the required scripts, such as "run_remote_search_handler.pl", to the remote server. For some reason, these don't get sent over otherwise!
    my @scriptsToTransfer = (File::Spec->catfile($self->local_scripts_dir(), "remote", "run_remote_parse_results_handler.pl"),
			     File::Spec->catfile($self->local_scripts_dir(), "remote", "run_parse_results.sh"),
			     File::Spec->catfile($self->local_scripts_dir(), "remote", "parse_results.pl"),
	); 
    foreach my $transferMe (@scriptsToTransfer) {
	$self->Shotmap::Run::transfer_file_into_directory($transferMe, ($self->remote_connection() . ':' . $self->remote_scripts_dir() . '/')); # transfer the script into the remote directory
    }
    
    # See "run_remote_search" in run_remote_search_handler.pl
    my $remote_cmd  = "\'" . "perl " . File::Spec->catfile($self->remote_scripts_dir(), "run_remote_parse_results_handler.pl")
	. " --resultdir=$remote_results_output_dir "
	. " --querydir=$remote_orf_dir "
	. " --dbname=$db_name "
	. " --nsplits=$nsplits "
	. " --scriptpath=${remote_script_path} "
	. " -w $waitTimeInSeconds "
	. " --sample-id=$sample_id "
#	. " --class-id=$classification_id "
	. " --algo=$type "
	. " --transmeth=$trans_method "
	. " --proj-dir=$proj_dir "
	. " --script-dir=$scripts_dir";
    if( defined( $t_score ) ){
	$remote_cmd .= " --score=$t_score ";
    }
    if( defined( $t_evalue ) ){
	$remote_cmd .= " --evalue=$t_evalue ";
    }
    if( defined( $t_coverage ) ){
	$remote_cmd .= " --coverage=$t_coverage ";
    }
    if( $forceparse ){
	$remote_cmd .= " --forceparse ";
    }
    $remote_cmd .=    "> ${log_file_prefix}.out 2> ${log_file_prefix}.err "
	. "\'"; # single quotes bracket this command for whatever reason

    my $results     = $self->Shotmap::Run::execute_ssh_cmd($self->remote_connection(), $remote_cmd, $verbose);
    (0 == $EXITVAL) or warn("Execution of command <$remote_cmd> returned non-zero exit code $EXITVAL. The remote reponse was: $results.");
    return $results;
}

sub get_remote_search_results {
    my($self, $sample_id, $type) = @_;
    ($type eq "blast" or $type eq "last" or $type eq "rapsearch" or $type eq "hmmsearch" or $type eq "hmmscan") or 
	die "Invalid type passed into get_remote_search_results! The invalid type was: \"$type\".";
    # Note that every sequence split has its *own* output dir, in order to cut back on the number of files per directory.
    my $in_orf_dir = File::Spec->catdir($self->get_sample_path($sample_id), "orfs"); # <-- Always the same input directory (orfs) no matter what the $type is.
    foreach my $in_orfs(@{$self->Shotmap::DB::get_split_sequence_paths($in_orf_dir, 0)}) { # get_split_sequence_paths is a like a custom version of "glob(...)". It may be eventually replaced by "glob."
	warn "Handling <$in_orfs>...";
#	my $remote_results_output_dir = File::Spec->catdir($self->get_remote_sample_path($sample_id), "search_results", $type);
#	my $remoteFile = $self->remote_connection() . ':' . "$remote_results_output_dir/$in_orfs/";
	my $remote_results_output_dir = $self->remote_connection() . ':' . File::Spec->catdir($self->remote_sample_path($sample_id), "search_results", $type, $in_orfs);
	my $local_search_res_dir  = File::Spec->catdir($self->get_sample_path($sample_id), "search_results", $type, $in_orfs);
#	Shotmap::Run::transfer_file_into_directory($remoteFile, "$local_search_res_dir/");
	if( $self->small_transfer ){ #only grab mysqld files
	    print "You have --small-transfer set, so I'm only grabbing the .mysqld files from the remote server.\n";
	    File::Path::make_path( $local_search_res_dir );
	    $self->Shotmap::Run::transfer_file_into_directory("$remote_results_output_dir/*.mysqld", "$local_search_res_dir/");	    
	} else { #grab everything
	    $self->Shotmap::Run::transfer_directory("$remote_results_output_dir", "$local_search_res_dir");
	}
    }
}

sub build_classification_maps_by_sample{
    my ($self, $sample_id, $class_id, $post_rare_reads) = @_; # $post_rare_reads is a hashref mapping sample to read_ids, may not be defined, meaning use all reads. Note that we no longer use post_rare_reads to rarefy (see Shotmap::DB::get_classified_orfs_by_sample)
    #create the outfile
    #my $map    = {}; #maps project_id -> sample_id -> read_id -> orf_id -> famid NO LONGER NEEDED SINCE WE USE R TO PARSE MAP
    my $output = $self->ffdb() . "/projects/" . $self->db_name . "/" . $self->project_id() . "/output/ClassificationMap_Sample_${sample_id}_ClassID_${class_id}";
    if( defined( $self->postrarefy_samples ) ){
	my @samples   = keys( %$post_rare_reads );
	#my $rare_size = keys( %{ $post_rare_reads->{ $samples[0] } } );
	my $rare_size = $self->postrarefy_samples;
	$output .= "_Rare_${rare_size}";
    }
    $output .= ".tab";
    print "Building a classification map for sample ${sample_id}. Will dump results to ${output}\n";
    open( OUT, ">$output" ) || die "Can't open $output for write in build_classification_map: $!";    
    print OUT join("\t", "PROJECT_ID", "SAMPLE_ID", "READ_ID", "ORF_ID", "TARGET_ID", "FAMID", "ALN_LENGTH", "READ_COUNT", "\n" );
    #how many reads should we count for relative abundance analysis?
    my $read_count;
    if(!defined( $self->postrarefy_samples() ) ){
	print( "Calculating classification results using all reads loaded into the database\n" );
#	$read_count = @{ $self->Shotmap::DB::get_read_ids_from_ffdb( $sample_id ) }; #need this for relative abundance calculations
	$read_count = $self->Shotmap::DB::get_reads_by_sample_id( $sample_id )->count();
    } else{
	$read_count = $self->postrarefy_samples();
    }
    #classify reads
    my $dbh  = $self->Shotmap::DB::build_dbh();
    $self->Shotmap::DB::classify_orfs_by_sample( $sample_id, $class_id, $dbh, $self->postrarefy_samples() );
    #now get the classified results for this sample, build classification map
    my $members_rs = $self->Shotmap::DB::get_classified_orfs_by_sample( $sample_id, $class_id, $dbh, $self->postrarefy_samples() );
    #did mysql return any results for this query?
    my $nrows = 0;
    $nrows    = $members_rs->rows();
    print "MySQL return $nrows rows for the above query.\n";
    if( $nrows == 0 ){
	warn "Since we returned no rows for this classification query, you might want to check the stringency of your classification parameters.\n";
	next;
    }
    my $max_rows  = 10000;
    my $must_pass = 0; #how many reads get dropped from SQL result set because not sampled in rarefaction stage. Should not be used any longer.
    while( my $rows = $members_rs->fetchall_arrayref( {}, $max_rows ) ){
	foreach my $row( @$rows ){
	    my $orf_alt_id = $row->{"orf_alt_id"};		
	    my $famid       = $row->{"famid"};
	    my $read_alt_id = $row->{"read_alt_id"};
	    my $target_id   = $row->{"target_id"};
	    my $aln_length  = $row->{"aln_length"};
	    print OUT join("\t", $self->project_id(), $sample_id, $read_alt_id, $orf_alt_id, $target_id, $famid, $aln_length, $read_count, "\n" );
	}
    }
    $self->Shotmap::DB::disconnect_dbh( $dbh );	
    close OUT;
}

sub calculate_abundances{
    my ( $self, $sample_id, $class_id, $abund_type, $norm_type ) = @_;
    my $abundance_parameter_id = $self->Shotmap::DB::get_abundance_parameter_id( $abund_type, $norm_type )->abundance_parameter_id();
    my $dbh  = $self->Shotmap::DB::build_dbh();
    my $members_rs = $self->Shotmap::DB::get_classified_orfs_by_sample( $sample_id, $class_id, $dbh, $self->postrarefy_samples() );
    #did mysql return any results for this query?
    my $nrows = 0;
    $nrows    = $members_rs->rows();
    print "MySQL return $nrows rows for the above query.\n";
    if( $nrows == 0 ){
	warn "Since we returned no rows for this classification query, you might want to check the stringency of your classification parameters.\n";
	next;
    }
    my $max_rows   = 10000;
    my $must_pass  = 0; #how many reads get dropped from SQL result set because not sampled in rarefaction stage. Should not be used any longer.
    my $abundances = {}; #maps families to abundances
    #question: can perl handle the math below? Perhaps we should do this in SQL instead?
    #could call R from Perl if necessary...
    #alternatively, we could touch the database with updates as we progress, keeping only the totals in memory
    while( my $rows = $members_rs->fetchall_arrayref( {}, $max_rows ) ){
	foreach my $row( @$rows ){
	    my $orf_alt_id = $row->{"orf_alt_id"};		
	    my $famid       = $row->{"famid"};
	    my $read_alt_id = $row->{"read_alt_id"};
	    my $target_id   = $row->{"target_id"};
	    my $aln_length  = $row->{"aln_length"};
	    my ( $target_length, $family_length );
	    if( $norm_type eq 'target_length' ){
		$target_length = $self->Shotmap::DB::get_target_length( $target_id );
	    } elsif( $norm_type eq 'family_length' ){
		$family_length = $self->Shotmap::DB::get_family_length( $famid );
	    }
	    if( $abund_type eq 'binary' ){
		my $raw;
		if( $norm_type eq 'none' ){
		    $raw = 1;
		} elsif( $norm_type eq 'target_length' ){
		    $raw = 1 / $target_length;
		} elsif( $norm_type eq 'family_length' ){
		    $raw = 1 / $family_length;
		} else{
		    die( "You selected a normalization type that I am not familiar with (<${norm_type}>). Must be either 'none', 'target_length', or 'family_length'\n" );
		}			    
		$abundances->{$famid}->{"raw"} += $raw;
		$abundances->{"total"}++; #we want RPKM like abundances here, so we don't carry the length of the gene/family in the total 		

	    } elsif( $abund_type eq 'coverage' ){ #number of bases in read that match the family
		my $coverage;
		#have to accumulate coverage totals for normalization as we loop
		if( $norm_type eq "none" ){
		    $coverage = $aln_length;
		} elsif( $norm_type eq "target_length" ){
		    $coverage = $aln_length / $target_length;
		} elsif( $norm_type eq "family_length" ){
		    $coverage = $aln_length / $family_length;
		} else{
		    die( "You selected a normalization type that I am not familiar with (<${norm_type}>). Must be either 'none', 'target_length', or 'family_length'\n" );
		}
		$abundances->{$famid}->{"raw"} += $coverage;
		$abundances->{"total"} += $coverage;
	    } else{
		die( "You are trying to calculate a type of abundance that I'm not aware of. Reveived <${abund_type}>. Exiting\n" );		
	    }	   
	}
    }
    #now that all of the classified reads are processed, calculate relative abundances
    my $total = $abundances->{"total"};
    foreach my $famid( keys( %{ $abundances } ) ){
	next if( $famid eq "total" );
	my $raw = $abundances->{$famid}->{"raw"};
	my $ra  = $raw / $total;
	#now, insert the data into mysql.
	$self->Shotmap::DB::insert_abundance( $sample_id, $famid, $raw, $ra, $abundance_parameter_id, $class_id );
    }
    $self->Shotmap::DB::disconnect_dbh( $dbh );	
    return $self;
}

sub get_post_rarefied_reads{
    my( $self, $sample_id, $read_number, $is_slim, $post_rare_reads ) = @_;
    if( !defined( $post_rare_reads ) ){
	$post_rare_reads = {}; #hashref that maps sample id to read ids
    }
    #first, get a list of read ids either from the flat file or the database
    my @read_ids = ();
    my @selected_ids = ();
    if( $is_slim ){ #get from the flat file
	@read_ids = @{ $self->Shotmap::DB::get_read_ids_from_ffdb( $sample_id ) };
	#make sure we're not asking for more sampled reads than there are reads in the DB
	if( scalar( @read_ids ) < $read_number ){
	    warn( "You are asking for $read_number sampled reads but I can only find " . scalar(@read_ids) . " for sample ${sample_id}. Exiting\n" );
	    die;
	}
	@selected_ids = @{ _random_sample_from_array( $read_number, \@read_ids ) };
    }
    else{ #get from the database
	my $reads = get_reads_by_sample_id( $sample_id );
	while( my $read = $reads->next ){
	    my $read_id = $read->read_id;
	    push( @read_ids, $read_id );
	}
	#make sure we're not asking for more sampled reads than there are reads in the DB
	if( scalar( @read_ids ) < $read_number ){
	    warn( "You are asking for $read_number sampled reads but I can only find " . scalar(@read_ids) . " for sample ${sample_id}. Exiting\n" );
	    die;
	}       
	@selected_ids = @{ _random_sample_from_array( $read_number, \@read_ids ) };
    }
    foreach my $selected_id( @selected_ids ){
	$post_rare_reads->{$sample_id}->{$selected_id}++; #should never be greater than 1.....
    }
    return $post_rare_reads;
}

sub build_intersample_abundance_map{
    my( $self, $class_id, $abund_param_id ) = @_;
    #dump family abundance data for each sample id to flat file
    my $outdir     = File::Spec->catdir( 
	$self->ffdb(), "projects", $self->db_name, $self->project_id(), "output" 
	);
    #my $abundances = $self->Shotmap::DB::get_sample_abundances( $sample_id, $class_id, $abund_param_id );
    my $sample_abund_out  = $outdir . "/Abundance_Map_cid_"         . "${class_id}_aid_${abund_param_id}.tab";
    my $sample_Rabund_out = $outdir . "/RelativeAbundance_Map_cid_" . "${class_id}_aid_${abund_param_id}.tab";
    open( ABUND, ">$sample_abund_out"  ) || die "Can't open $sample_abund_out for write: $!\n";
    open( RA, "   >$sample_Rabund_out" ) || die "Can't open $sample_Rabund_out for write: $!\n";
    my $max_rows          = 10000;
    my $dbh               = $self->Shotmap::DB::build_dbh();
    my $famids            = {};
    my $counter           = 0; #how many samples have we processed
    foreach my $sample_id( @{ $self->get_sample_ids() } ){
	$counter++;
	my $values            = {};
	my $abunds_rs         = $self->Shotmap::DB::get_sample_abundances_for_all_classed_fams( $dbh, $sample_id, $class_id, $abund_param_id );
	while( my $rows = $abunds_rs->fetchall_arrayref( {}, $max_rows ) ){
	    foreach my $row( @$rows ){
		my $famid              = $row->{"famid"};
		my $abundance          = $row->{"abundance"};
		my $relative_abundance = $row->{"relative_abundance"};
		if( !defined( $abundance) ){
		    $values->{$famid}->{"raw"} = 0;
		    $values->{$famid}->{"ra"}  = 0;
		} else {
		    $values->{$famid}->{"raw"} = $abundance;
		    $values->{$famid}->{"ra"}  = $relative_abundance;
		}
		if( $counter == 1 ){
		    $famids->{$famid}++;
		}
	    }
	}
	if( $counter == 1 ){ #printer header row
	    my @col_names = sort( keys( %{ $famids } ) );
	    print ABUND join( "\t", @col_names, "\n" );
	    print RA join( "\t", @col_names, "\n" );
	}
	print ABUND "${sample_id}\t";
	print RA    "${sample_id}\t";
	foreach my $fam( sort( keys( %{ $famids } ) ) ){
	    if( !defined( $values->{$fam} ) ){
		die( "Couldn't find an abundance value for family ${fam} in sample ${sample_id}'s data. Exiting!\n" );
	    }	    
	    print ABUND $values->{$fam}->{"raw"} . "\t";
	    print RA    $values->{$fam}->{"ra"}  . "\t";	    
	}
	print ABUND "\n";
	print RA    "\n";
    }
    $self->Shotmap::DB::disconnect_dbh( $dbh );	
    close ABUND;
    close RA;
    return $self;
}

sub delete_prior_project{
    my $self = shift;
    foreach my $sample_alt_id( keys ( %{$self->get_sample_hashref() } ) ){
	my $pid = $self->Shotmap::DB::get_project_by_sample_alt_id( $sample_alt_id );
	$self->Shotmap::Run::clean_project( $pid );
	last;
    }    
    return $self;
}

sub check_prior_analyses{
    my ( $self, $reload ) = @_;
    foreach my $sample_alt_id( keys ( %{$self->get_sample_hashref() } ) ){
	my $sample = $self->Shotmap::DB::get_sample_by_alt_id( $sample_alt_id );
	if( defined( $sample ) ){
	    warn( "The sample $sample_alt_id already exists in the database under sample_id " . $sample->sample_id() . "!\n" );
	    if( $reload ){
		warn( "Since you specified --reload, I am deleting prior versions of this sample from the database" );
		$self->Shotmap::DB::delete_sample( $sample->sample_id() );
	    } else {
		print STDERR ("*" x 80 . "\n");
		print STDERR ("Before proceeding, you must either remove this sample from your project or delete the sample's prior data from the database. You can do this as follows:\n");
		print STDERR (" Option A: Rerun your mcr_handler.pl command, but add the --reload option\n" );
		print STDERR (" Option B: Use MySQL to remove the old data, as follows:\n" );
		print STDERR ("   1. Go to your database server (probably " . $self->get_db_hostname() . ")\n");
		print STDERR ("   2. Log into mysql with this command: mysql -u YOURNAME -p   <--- YOURNAME is probably \"" . $self->get_username() . "\"\n");
		print STDERR ("   3. Type these commands in mysql: use ***THE DATABASE***;   <--- THE DATABASE is probably " . $self->get_db_name() . "\n");
		print STDERR ("   4.                        mysql: select * from samples;    <--- just to look at the projects.\n");
		print STDERR ("   5.                        mysql: delete from samples where sample_id=" . $sample->sample_id . ";    <-- actually deletes this project.\n");
		print STDERR ("   6. Then you can log out of mysql and hopefully re-run this script successfully!\n");
		print STDERR ("   7. You MAY also need to delete the entry from the 'samples' table in MySQL that has the same name as this sample/proejct.\n");
		print STDERR ("   8. Try connecting to mysql, then typing 'select * from samples;' . You should see an OLD project ID (but with the same textual name as this one) that may be preventing you from running another analysis. Delete that id ('delete from samples where sample_id=the_bad_id;'");
		my $mrcCleanCommand = (qq{perl \$Shotmap_LOCAL/scripts/mrc_clean_project.pl} 
				       . qq{ --pid=} . $sample->project_id
				       . qq{ --dbuser=} . $self->get_username()
				       . qq{ --dbpass=} . "PUT_YOUR_PASSWORD_HERE"
				       . qq{ --dbhost=} . $self->get_db_hostname()
				       . qq{ --ffdb=}   . $self->ffdb()
				       . qq{ --dbname=} . $self->get_db_name()
				       . qq{ --schema=} . $self->{"schema_name"});
		print STDERR (" Option C: Run mrc_cleand_project.pl as follows:\n" );
		print STDERR ("$mrcCleanCommand\n");
		print STDERR ("*" x 80 . "\n");
		die "Terminating: Duplicate database entry error! See above for a possible solution.";
	    }
	}    
    }
    return $self;
}

sub check_sample_rarefaction_depth{
    my ( $self, $sample_id, $post_rare_reads ) = @_;
    my $bit = 1;
    return $bit if( !defined( $post_rare_reads ) );
    my $reads = $self->Shotmap::DB::get_reads_by_sample( $sample_id );
    if( $reads->count() > $post_rare_reads ){
	warn( "There are not enough reads in sample ${sample_id} to rarefy to a depth of ${post_rare_reads}. I will have to skip all downstream analyses for this sample.\n" );
	$bit = 0;
    }
    return $bit;
}

sub calculate_diversity{
    my( $self, $class_id, $abund_param_id ) = @_; #abundance type is "abundance" or "relative_abundance"
    #set output directory
    my $outdir          = File::Spec->catdir( $self->ffdb(), "projects", $self->db_name, $self->project_id(), "output" );
    my $scripts_dir     = $self->local_scripts_dir();
    #build a sample metadata table that maps sample_id to metadata properties. dump to file
    my $metadata_table  = $self->Shotmap::Run::get_project_metadata();
    my $abund_map   = $outdir . "/Abundance_Map_cid_"         . "${class_id}_aid_${abund_param_id}.tab";
    my $r_abund_map = $outdir . "/RelativeAbundance_Map_cid_" . "${class_id}_aid_${abund_param_id}.tab";

    #CALCULATE DIVERSITY AND COMPARE SAMPLES
    #open output directory that contains per sample diversity data
    my $sample_diversity_prefix  = $outdir . "/Sample_Diversity_cid_${class_id}_aid_${abund_param_id}";
    my $compare_diversity_prefix = $outdir . "/Compare_samples_cid_${class_id}_aid_${abund_param_id}";
    #run an R script that groups samples by metadata parameters and identifies differences in diversity distributions
    #produce pltos and output tables
    my $script            = File::Spec->catdir( $scripts_dir, "R", "calculate_diversity.R" );
    my $cmd               = "R --slave --args ${abund_map} ${r_abund_map} ${metadata_table} ${sample_diversity_prefix} ${compare_diversity_prefix} < ${script}";
    print $cmd . "\n";
    Shotmap::Notify::exec_and_die_on_nonzero( $cmd );

    #ADD BETA-DIVERSITY ANALYSES TO THE ABOVE OR AN INDEPENDENT FUNCTION

    #INTERFAMILY ANALYSIS
    #open directory that contains sample-famid abundance maps for all samples for given class/abundparam id
    my $family_abundance_prefix = $outdir . "/Family_Abundances";
    my $intrafamily_prefix      = $outdir . "/Compare_families_cid_${class_id}_aid_${abund_param_id}";
    #run an R script that groups samples by metadata parameters and calculates family-level variance w/in and between groups
    #produce plots and output tables for this analysis
    $script            = File::Spec->catdir( $scripts_dir, "R", "compare_families.R" );
    $cmd               = "R --slave --args ${abund_map} ${r_abund_map} ${metadata_table} ${family_abundance_prefix} ${intrafamily_prefix} < ${script}";
    Shotmap::Notify::exec_and_die_on_nonzero( $cmd );       

    #COMPARE SAMPLES BY MULTIDIMENSIONAL SCALING
    #use family abundance tables to conduct a PCA analysis of the samples, producing a loadings table and biplot as output
    my $pca_prefix              = $outdir . "/Sample_PCA";
    $script                     = File::Spec->catdir( $scripts_dir, "R", "sample_pca.R" );
    $cmd                        = "R --slave --args ${abund_map} ${r_abund_map} ${metadata_table} ${family_abundance_prefix} ${pca_prefix} < ${script}";
    $self;
}

#MODIFIED
sub get_project_metadata{
    my( $self )  = @_;
    my $output   = File::Spec->catdir( $self->ffdb, "projects", $self->db_name, $self->project_id(), "output", "sample_metadata.tab" );
    my $samples  = $self->Shotmap::DB::get_samples_by_project_id( $self->project_id() );
    open( OUT, ">$output" ) || die "Can't open $output for write: $!\n";
    my $data   = {}; #will push rows to data, need to know all fields before printing header
    my $fields = {};
    while( my $row = $samples->next ){
	my $sample_id     = $row->sample_id;
	my $sample_alt_id = $row->sample_alt_id;
	$data->{$sample_id}->{"alt_id"} = $sample_alt_id;
	my $metadata      = $row->metadata;
	my( @fields )  = split( ",", $metadata );
	foreach my $field( @fields ){
	    my( $field_name, $field_value ) = split( "\=", $field );
	    $data->{$sample_id}->{"metadata"}->{$field_name} = $field_value;
	    $fields->{$field_name}++;
	}
    }
    #print the header
    print OUT join( "\t", "SAMPLE.ID", "SAMPLE.ALT.ID", sort(map{ uc($_) } keys(%{$fields})), "\n" );
    foreach my $sample_id( keys( %{ $data } ) ){
	my $sample_alt_id = $data->{$sample_id}->{"alt_id"};
	print OUT join( "\t", $sample_id, $sample_alt_id, $sample_id );
	my @fields        = keys( %{ $data->{$sample_id}->{"metadata"} } );
	foreach my $field( sort( @fields ) ){
	    if( $field eq $fields[-1] ){
		print OUT $data->{$sample_id}->{"metadata"}->{$field} . "\n";
	    } else{
		print OUT $data->{$sample_id}->{"metadata"}->{$field} . "\t";
	    }
	}   
    }
    close OUT;
    return $output;
}

1;
