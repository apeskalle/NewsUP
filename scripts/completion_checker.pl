# Author: David Santiago <demanuel@ymail.com>
# This program is licensed under GPLv3
use 5.018;
use strict;
use warnings;
use utf8;

use Getopt::Long;
use Config::Tiny;
use XML::LibXML qw(:threads_shared);
use IO::Socket::INET;
use IO::Socket::SSL;# qw(debug3);
use threads;
use threads::shared;

use Data::Dumper;
sub main{

  my ($server, $port, $username, $userpasswd,@nzbs);
  GetOptions('server=s'=>\$server,
	     'port=i'=>\$port,
	     'username=s'=>\$username,
	     'password=s'=>\$userpasswd,
	     'nzb|file=s'=>\@nzbs,
	    );

  if (!@nzbs) {
    say "Please define which NZBs you want to check!";
    exit 1;
  }else {
    for (@nzbs) {
      if (!-e $_) {
	say "$_ not found! Please confirm!";
	exit 2;
      }
    }
  }
  if (defined $ENV{"HOME"} && -e $ENV{"HOME"}.'/.config/newsup.conf') {
    
    my $config = Config::Tiny->read( $ENV{"HOME"}.'/.config/newsup.conf' );
    my %metadata = %{$config->{metadata}};


    if (!defined $server) {
      $server = $config->{server}{server} if exists $config->{server}{server};
    }
    if (!defined $port) {
      $port = $config->{server}{port} if exists $config->{server}{port};
    }
    if (!defined $username) {
      $username = $config->{auth}{user} if exists $config->{auth}{user};
    }
    if (!defined $userpasswd) {
      $userpasswd = $config->{auth}{password} if exists $config->{auth}{password};
    }

    if (!defined $server || !defined $port || !defined $username || !defined $userpasswd) {
      say "Please check the parameters server, port, username, password";
      exit 1;
    }
  }

  
  my $socket = _create_socket ($server, $port);
  if (_authenticate($socket, $username, $userpasswd) == -1) {
    say "Please verify the credentials";
    exit 2;
  }

  my $incomplete = verify_nzbs($socket,\@nzbs);
  _logout($socket);
  exit 3 if $incomplete == 1;
}


sub _create_socket{
  my ($server, $port) = @_;

  my $socket;
  if ($port != 119) {
    $socket = IO::Socket::SSL->new(
				   PeerHost=>$server,
				   PeerPort=>$port,
				   SSL_verify_mode=>SSL_VERIFY_NONE,
				   SSL_version=>'TLSv1',
				   #SSL_version=>'TLSv1_2',
				   #SSL_cipher_list=>'DHE-RSA-AES128-SHA',
				   SSL_ca_path=>'/etc/ssl/certs',
				  ) or die "Failed to connect or ssl handshake: $!, $SSL_ERROR";
  }else {
    $socket = IO::Socket::INET->new (
				     PeerAddr => $server,
				     PeerPort => $port,
				     Proto => 'tcp',
				    ) or die "ERROR in Socket Creation : $!\n";
  }

  
  $socket->autoflush(1);
  sysread($socket, my $output, 8192);

  return $socket;

  
}

sub _authenticate{
  my ($socket, $user, $passwd) = @_;

  print $socket "authinfo user $user\r\n";
  sysread($socket, my $output, 8192);
  my $status = substr($output,0,3);
  if ($status != 381) {
    shutdown $socket, 2;
    return -1;
  }
  #my $password=$self->{userpass};
  print $socket "authinfo pass $passwd\r\n";
  sysread($socket, $output, 8192);
  $status = substr($output,0,3);
  if ($status != 281 && $status != 250) {
    shutdown $socket, 2;
    return -1;
  }
  return 1;

}

sub verify_nzbs{
  my ($socket, $nzbs) =@_;

  my $currentGroup='';
  my $incomplete=0;
  for (@$nzbs) {
    my $parser = XML::LibXML->new();
    my $doc = $parser->parse_file( $_ );

    my @nzbFiles = sort{
		    $a->getAttribute('subject') cmp $b->getAttribute('subject')
		  } @{$doc->getElementsByTagName("file")};

    
    for my $file (@nzbFiles) {
      my $group = $file->getElementsByTagName('group')->[0]->textContent;
      my ($output, $existingSegments)=('',0);
      if ($group ne $currentGroup) {
	print $socket "group $group\r\n";
	sysread($socket, $output, 8192);
	$currentGroup = $group;
      }

      my @segments = @{$file->getElementsByTagName('segment')};

      my $totalSegments=@segments;
      my @segmentsByConnection = ();
      
      my $connections=1;
      my $i = 0;
      for (@segments) {
	push @{$segmentsByConnection[$i]}, ($_);
	$i+=1;
	$i=0 if $i==$connections;
      }
      
#      say Dumper(@segmentsByConnection);

      $existingSegments= _verify_segments( $socket, $segmentsByConnection[$i]);
      
      $incomplete = 1 if @{$file->getElementsByTagName('segment') } != $existingSegments;
      my $percentage = $existingSegments/@{$file->getElementsByTagName('segment') }* 100.0;
      #      say "Percentagem: $percentage";
      $file->getAttribute('subject')=~ /\"(.*)\"/;
      my $fileName = $1;
      printf("File %s is %f%% completed\r\n",$fileName, $percentage );
      
    }
    
    
  }

  return $incomplete;
}


sub _verify_segments{
  my ($socket, $segments) = @_;
  my $output ='';
  my $existingSegments=0;
  for (@$segments) {
    
    my $segmentID = $_->textContent;
    print $socket "stat <$segmentID>\r\n";
    sysread($socket, $output, 8192);
    chomp $output;
    $existingSegments +=1 if (substr($output,0,3) == 223);
  }
  return $existingSegments;

}

sub _logout{
  my $socket = shift;
  print $socket "quit\r\n";
  shutdown $socket, 2;  
}

main;
