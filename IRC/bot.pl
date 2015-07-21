#!/usr/local/bin/perl -w
##########################################################################
#     Copyright (C) David Santiago
#  
#     This program is free software: you can redistribute it and/or modify
#     it under the terms of the GNU General Public License as published by
#     the Free Software Foundation, either version 3 of the License, or
#     (at your option) any later version.
#
#     This program is distributed in the hope that it will be useful,
#     but WITHOUT ANY WARRANTY; without even the implied warranty of
#     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#     GNU General Public License for more details.
#
#     You should have received a copy of the GNU General Public License
#     along with this program.  If not, see <http://www.gnu.org/licenses/>.
##############################################################################
# A simple IRC robot. Influenced by http://archive.oreilly.com/pub/h/1964
# Usage: perl bot.pl -folder <folder> -uploadit <uploadit> script
#############################################################################

use warnings;
use strict;
use utf8;
use 5.010;
use Data::Dumper;
use Getopt::Long;
use Config::Tiny;

# We will use a raw socket to connect to the IRC server.
use IO::Socket;
use File::Copy::Recursive qw/dircopy/;
use File::Copy qw/mv/;
use File::Path qw/remove_tree/;

sub main{
  my $config = get_options();
  my $socket = get_IRC_socket($config);
  
  start($socket, $config);
}


sub get_options{

  my $config;
  if (defined $ENV{"HOME"} && -e $ENV{"HOME"}.'/.config/newsup.conf') {
    
    $config = Config::Tiny->read( $ENV{"HOME"}.'/.config/newsup.conf' );
    if (exists $config->{other}{PATH_TO_UPLOAD_ROOT}){
      my @upload_folders = split(',', $config->{other}{PATH_TO_UPLOAD_ROOT});
      if (!@upload_folders) {
	say "Please configure PATH_TO_UPLOAD_ROOT folders";
	exit 0;
      }
      for (@upload_folders) {
	$_ =~ s/^\s+|\s+$//g ;     # remove both leading and trailing whitespace
	
	if (!-d $_) {
	  say "Folder $_ does not exist!\r\nPlease configure correctly the option PATH_TO_UPLOAD_ROOT Exiting.";
	  exit;
	}
      }
    
    }else {
      say "Option PATH_TO_UPLOAD_ROOT is missing!";
    }
    if (exists $config->{other}{PATH_TO_SAVE_NZBS}){
      my $NZB_folder = $config->{other}{PATH_TO_SAVE_NZBS};
      if (!-d $NZB_folder) {
	say "Please configure PATH_TO_SAVE_NZBS_ROOT folders";
	exit 0;
      }
      
    }else {
      say "Option PATH_TO_SAVE_NZBS is missing!";
    }
    
    
  }else {
    say "Please configure your newsup.conf file";
    exit 0;
  }

  return $config;
}
  

sub get_IRC_socket{
  my $config = shift;
  my $sock = new IO::Socket::INET(PeerAddr => $config->{other}{IRC_SERVER},
				  PeerPort => $config->{other}{IRC_PORT},
				  Proto => 'tcp') or
                                    die "Can't connect\n";

  my $nick = $config->{other}{IRC_NICK};
  
  # Log on to the server.
  print $sock "NICK $nick\r\n";
  #print $sock "USER $login 8 * :NewsUp TEST \r\n";
  print $sock "USER $nick * * :NewsUp\r\n";

  # Read lines from the server until it tells us we have connected.
  while (my $input = <$sock>) {
    say "input: $input";
    # Check the numerical responses from the server.
    if ($input =~ /004/) {
      # We are now logged in.
      last;
    }
    elsif ($input =~ /433/) {
      die "Nickname is already in use.";
    }
  }
  
  # Join the channel.
  my $channel = $config->{other}{IRC_CHANNEL};
  print $sock "JOIN #$channel\r\n";

  return $sock;
  
}


sub start{
  my $socket = shift;
  my $config = shift;
  my $nick = $config->{other}{IRC_NICK};
  my $channel = '#'.$config->{other}{IRC_CHANNEL};
  
  # Keep reading lines from the server.
  while (my $input = <$socket>) {
    $input=~s/\R$//;
    say $input;
    if ($input =~ /^PING(.*)$/i) {
      # We must respond to PINGs to avoid being disconnected.
      print $socket "PONG $1\r\n";
    }else {
      my @tokens = split(' ', $input);

      if (@tokens) {
	if ($tokens[1] eq 'PRIVMSG') {
	  $tokens[0]=~ /^:(.*)\!.*$/;

	  my @inputParams= ($1 , substr join(' ',@tokens[3..$#tokens]), 1);
	  if ($tokens[2] eq $nick) {#private message

	    if ($inputParams[1]=~ /^echo (.*)$/) {
	      print $socket 'PRIVMSG '.$inputParams[0].' :You told me "'.substr($inputParams[1],5)."\"\r\n"; #Write to user. The substr is to avoid printing the command
	      print $socket "PRIVMSG $channel :User ".$inputParams[0].' told me '.substr($inputParams[1],5)."\r\n"; #Write to the channel
	      
	    }elsif($inputParams[1]=~ /^fortune.*$/){
	      my $fortune = `fortune chucknorris`;
	      $fortune=~s/\R//g;
	      say "PRIVMSG $channel :$fortune\r\n";
	      print $socket "PRIVMSG $channel :$fortune\r\n";# Write to the channel
	      
	    }
	    
	  }elsif ($tokens[2] eq $channel) {#public message
	    say "Public message: '".$inputParams[1]."'";
	    if($inputParams[1] =~ /newsup/i){
	      
	      my @randomMessages = ("Er... Ok...", "Are you sure?", "I believe", "Damn!", "Why not?", ":-D","Maybe later", "Was that a public annoucement?!?");
	      print $socket "PRIVMSG $channel :".$randomMessages[rand @randomMessages]."\r\n";
	    }
	    elsif ($inputParams[1] =~ /^\!(\w+) (.*)$/) {# All the public commands must start with a !

	      if ($1 eq 'upload') {
		my @args = split(' ', $2);
		say "Starting !upload".Dumper(@args);
		start_upload (\@args, $socket, $config);
	      }elsif ($1 eq 'check') {
		my @args = split(' ', $2);
		check_nzb(\@args, $socket, $config);
	      }  
	    }
	    else {
	      say "Didn't match!";
	    }
	  }
	}
      }
    }
  }
}

sub check_nzb{
  my @args = @{shift @_};
  my $socket = shift;
  my $config = shift;
  
  my $channel = "#".$config->{other}{IRC_CHANNEL};
  my $uploadit = $config->{other}{PATH_TO_UPLOADIT};
  my $newsup = $config->{other}{PATH_TO_UPLOADER};
  
  unless (defined(my $pid = fork())) {
    say "Unable to fork! Exiting the bot";
    exit 0;
  }
  elsif ($pid) {
    #The main process
    return;
  }
  
  #Im the child
  for my $nzb (@args) {
    if (!-e $config->{other}{PATH_TO_SAVE_NZBS}."/$nzb.nzb") {
      say "Not found: ".$config->{other}{PATH_TO_SAVE_NZBS}."/$nzb.nzb";
      print $socket "PRIVMSG $channel : $nzb not found!\r\n"
    }else {
      my $cmd = $config->{other}{PATH_TO_COMPLETION_CHECKER}." -nzb ".$config->{other}{PATH_TO_SAVE_NZBS}."/$nzb.nzb";
      say "Executing: $cmd";
      my $output = qx/$cmd/;
      print $socket "PRIVMSG $channel : $_\r\n" for (split($/,$output));
    }
  }
  exit 0;
}


sub start_upload{
  my @args = @{shift @_};
  my $socket = shift;
  my $config = shift;
  
  my $channel = "#".$config->{other}{IRC_CHANNEL};
  my $uploadit = $config->{other}{PATH_TO_UPLOADIT};
  my $newsup = $config->{other}{PATH_TO_UPLOADER};
  
  unless (defined(my $pid = fork())) {
    say "Unable to fork! Exiting the bot";
    exit 0;
  }
  elsif ($pid) {
    #The main process
    return;
  }
  
  #Im the child
  my $ads = 0;
  if ($args[-1] eq '-ads') {
    $ads = 1;
    pop @args;
  }
  
  
  if (@args >= 2) {
    my $folder = shift @args;

    my $rootFolder = '';
    for my $val (split(',',$config->{other}{PATH_TO_UPLOAD_ROOT})) {
      $val =~ s/^\s+|\s+$//g; #Remove both leading and trainline whitespace
      if (-d "$val/$folder") {
	$rootFolder="$val/$folder";
	last;
	say "Found!";
      }
      say "Plus 1";
    }

    if (!$rootFolder) {
      print $socket "PRIVMSG $channel : $folder not found!\r\n";
      exit 0;
    }
    
    say "Copying the files: $rootFolder -> ".$args[0];
    my $currentFolder = $config->{other}{TEMP_DIR}.'/'.$args[0];
    dircopy($rootFolder, $currentFolder) or die $!;
    dircopy($config->{other}{PATH_TO_ADS}, $currentFolder."/Usenet/");
    
    my @files = upload_folder($newsup, $uploadit, $currentFolder,
			      $config->{other}{PATH_TO_SAVE_NZBS}.'/'.$args[0],
			      $config->{other}{PATH_TO_SAVE_NZBS},
			      $socket, $channel);

    say "Uploaded Files: $_" for @files;
    for (my $i =1; $i < @args; $i++) {
      my $toReplace = $args[$i-1];
      my $replacement = $args[$i];
      my @newFiles = ();
      say "To replace: $toReplace";
      say "Replacement: $replacement";
      for my $oldName (@files) {
	(my $newName = $oldName) =~ s/$toReplace/$replacement/;
	push @newFiles, $newName;

	say "new name: $newName";
	if ($oldName =~ /\.sfv/) {
	  open my $ih, '<', $oldName;
	  open my $oh, '>', $newName;
	  while (<$ih>) {
	    s/$toReplace/$replacement/;
	    print $oh "$_";
	  }
	  close $ih;
	  close $oh;
	  unlink $oldName;
	  
	}else {
	  rename $oldName, $newName;
	}
      }

      say "Upload files: $_" for @newFiles;
      upload_files($newsup, \@newFiles, $socket, $channel);

      @files = @newFiles;
      
      if ($i==$#args) {
	remove_tree($currentFolder);
	say "Removing files: $_" for @newFiles;
	unlink @newFiles;
      }

    }
    
  }
  
  exit 0;
}

sub upload_folder{
  my ($newsup, $uploadit, $folder, $nzb, $nzbFolder ,$socket, $channel) =@_;

  my $cmd = "$uploadit -nodelete -directory $folder -a \"-nzb $nzb\"";

  my @files = ();
  
  say "Executing: $cmd";
  my $output = qx($cmd);
  for (split($/,$output)){
    # if ($_ =~/NZB file (.*) created/){
    #   mv $nzb, $nzbFolder;
    # }els
    if ($_ =~ /Transfer speed/) {
      print $socket "PRIVMSG $channel : $_\r\n"
    }elsif ($_ =~ /Uploaded files: (.*)/) {
      push @files, $1;
    }
  }

  $output = qx($newsup -f $nzb.nzb -nzb "./nzb"); #upload the nzb
  say "$output";
  unlink "./nzb.nzb";
  return @files;
}


sub upload_files{
  my ($newsup, $files, $socket, $channel) = @_;
  my $cmd = "$newsup";
  $cmd .= " -f \"$_\"" for @$files;

  say "Executing: $cmd";
  my $output = qx($cmd);
  for (split($/,$output)){
    if ($_ =~/NZB file (.*) created/){
      unlink $1;
    }elsif ($_ =~ /Transfer speed/) {
      print $socket "PRIVMSG $channel : $_\r\n"
    }
  }

  
}

main;