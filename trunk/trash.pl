#!/usr/bin/perl

# $Header$

#######################################################################
#   Program name    trash.pl                                          #
#   Written by      Rick Sanders                                      #
#   Date            10/7/2003                                         #
#                                                                     #
#   Description                                                       #
#                                                                     #
#   This script checks a user's IMAP mailboxes for deleted messages   #
#   which it moves to the trash mailbox.  Optionally the trash        #
#   mailbox is emptied.                                               #       
#                                                                     #
#   trash.pl is called like this:                                     #
#       ./trash.pl -S host/user/password                              # 
#                                                                     #
#   Optional arguments:                                               #
#	-d debug                                                      #
#       -t <trash mailbox name> (defaults to 'Trash')                 #
#       -e empty the trash mailbox (default is not to empty it)       #
#       -L <logfile>                                                  #
#       -m mailbox list (check just certain mailboxes,see usage notes)#
#######################################################################

use Socket;
use FileHandle;
use Fcntl;
use Getopt::Std;


#################################################################
#            Main program.                                      #
#################################################################

   &init();
   &sigprc();

   #  Get list of all messages on the source host by Message-Id
   #
   &connectToHost($sourceHost, 'SRC');
   &login($sourceUser,$sourcePwd, 'SRC');
   @mbxs = &getMailboxList($sourceUser, 'SRC');

   print STDOUT "Checking mailboxes for deleted messages...\n";
   foreach $mbx ( @mbxs ) {
       print STDOUT "   Checking mailbox $mbx for deleted messages\n" if $debug;
       %msgList = ();
       @sourceMsgs = ();
       &getDeletedMsgs( $mbx, \@msgs, 'SRC' ); 
       &moveToTrash( $mbx, $trash, \@msgs, 'SRC' );
       &expungeMbx( $mbx, 'SRC' );
   }

   print STDOUT "\n$total messages were moved to $trash\n";

   if ( $emptyTrash && ($total > 0) ) {
      &expungeMbx( $trash, 'SRC' );
      print STDOUT "The $trash mailbox has been emptied\n\n";
   }

   &logout( 'SRC' );

   exit;


sub init {

   $version = 'V1.0';
   $os = $ENV{'OS'};

   &processArgs;

   if ($timeout eq '') { $timeout = 60; }

   #  Open the logFile
   #
   if ( $logfile ) {
      if ( !open(LOG, ">> $logfile")) {
         print STDOUT "Can't open $logfile: $!\n";
      } 
      select(LOG); $| = 1;
   }
   &Log("\n$0 starting");
   $total=0;

}

#
#  sendCommand
#
#  This subroutine formats and sends an IMAP protocol command to an
#  IMAP server on a specified connection.
#

sub sendCommand
{
    local($fd) = shift @_;
    local($cmd) = shift @_;

    print $fd "$cmd\r\n";

    if ($showIMAP) { &Log (">> $cmd",2); }
}

#
#  readResponse
#
#  This subroutine reads and formats an IMAP protocol response from an
#  IMAP server on a specified connection.
#

sub readResponse
{
    local($fd) = shift @_;

    $response = <$fd>;
    chop $response;
    $response =~ s/\r//g;
    push (@response,$response);
    if ($showIMAP) { &Log ("<< $response",2); }
}

#
#  Log
#
#  This subroutine formats and writes a log message to STDERR.
#

sub Log {
 
my $str = shift;

   #  If a logile has been specified then write the output to it
   #  Otherwise write it to STDOUT

   if ( $logfile ) {
      ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime;
      if ($year < 99) { $yr = 2000; }
      else { $yr = 1900; }
      $line = sprintf ("%.2d-%.2d-%d.%.2d:%.2d:%.2d %s %s\n",
		     $mon + 1, $mday, $year + $yr, $hour, $min, $sec,$$,$str);
      print LOG "$line";
   } else {
      print STDOUT "$str\n";
   }

}

#  connectToHost
#
#  Make an IMAP4 connection to a host
# 
sub connectToHost {

my $host = shift;
my $conn = shift;

   &Log("Connecting to $host") if $debug;

   $sockaddr = 'S n a4 x8';
   ($name, $aliases, $proto) = getprotobyname('tcp');
   ($host,$port) = split(/:/, $host);
   $port = 143 if !$port;

   if ($host eq "") {
	&Log ("no remote host defined");
	close LOG; 
	exit (1);
   }

   ($name, $aliases, $type, $len, $serverAddr) = gethostbyname ($host);
   if (!$serverAddr) {
	&Log ("$host: unknown host");
	close LOG; 
	exit (1);
   }

   #  Connect to the IMAP4 server
   #

   $server = pack ($sockaddr, &AF_INET, $port, $serverAddr);
   if (! socket($conn, &PF_INET, &SOCK_STREAM, $proto) ) {
	&Log ("socket: $!");    
	close LOG;
	exit (1);
   }
   if ( ! connect( $conn, $server ) ) {
	&Log ("connect: $!");
	return 0;
   }

   select( $conn ); $| = 1;
   while (1) {
	&readResponse ( $conn );
	if ( $response =~ /^\* OK/i ) {
	   last;
	}
	else {
 	   &Log ("Can't connect to host on port $port: $response");
	   return 0;
	}
   }
   &Log ("connected to $host") if $debug;

   select( $conn ); $| = 1;
   return 1;
}

#  trim
#
#  remove leading and trailing spaces from a string
sub trim {
 
local (*string) = @_;

   $string =~ s/^\s+//;
   $string =~ s/\s+$//;

   return;
}


#  login
#
#  login in at the source host with the user's name and password
#
sub login {

my $user = shift;
my $pwd  = shift;
my $conn = shift;

   $rsn = 1;
   &sendCommand ($conn, "$rsn LOGIN $user $pwd");
   while (1) {
	&readResponse ( $conn );
	if ($response =~ /^$rsn OK/i) {
		last;
	}
	elsif ($response =~ /NO/) {
		&Log ("unexpected LOGIN response: $response");
		return 0;
	}
   }
   &Log("Logged in as $user") if $debug;

   return 1;
}


#  logout
#
#  log out from the host
#
sub logout {

my $conn = shift;

   ++$lsn;
   undef @response;
   &sendCommand ($conn, "$lsn LOGOUT");
   while ( 1 ) {
	&readResponse ($conn);
	if ( $response =~ /^$lsn OK/i ) {
		last;
	}
	elsif ( $response !~ /^\*/ ) {
		&Log ("unexpected LOGOUT response: $response");
		last;
	}
   }
   close $conn;
   return;
}


#  getMailboxList
#
#  get a list of the user's mailboxes from the source host
#
sub getMailboxList {

my $user = shift;
my $conn = shift;
my @mbxs;

   #  Get a list of the user's mailboxes
   #
  if ( $mbxList ) {
      #  The user has supplied a list of mailboxes so only processes
      #  the ones in that list
      @mbxs = split(/,/, $mbxList);
      for $i (0..$#mbxs ) { 
	$mbxs[$i] =~ s/^\s+//; 
	$mbxs[$i] =~ s/s+$//; 
      }
      return @mbxs;
   }

   if ($debugMode) { &Log("Get list of user's mailboxes",2); }

   &sendCommand ($conn, "$rsn LIST \"\" *");
   undef @response;
   while ( 1 ) {
	&readResponse ($conn);
	if ( $response =~ /^$rsn OK/i ) {
		last;
	}
	elsif ( $response !~ /^\*/ ) {
		&Log ("unexpected response: $response");
		return 0;
	}
   }

   undef @mbxs;
   for $i (0 .. $#response) {
	# print STDERR "$response[$i]\n";
	$response[$i] =~ s/\s+/ /;
	($dmy,$mbx) = split(/"\/"/,$response[$i]);
	$mbx =~ s/^\s+//;  $mbx =~ s/\s+$//;
	$mbx =~ s/"//g;

	if ($response[$i] =~ /NOSELECT/i) {
		if ($debugMode) { &Log("$mbx is set NOSELECT,skip it",2); }
		next;
	}
	if (($mbx =~ /^\#/) && ($user ne 'anonymous')) {
		#  Skip public mbxs unless we are migrating them
		next;
	}
	if ($mbx =~ /^\./) {
		# Skip mailboxes starting with a dot
		next;
	}
	push ( @mbxs, $mbx ) if $mbx ne '';
   }

   if ( $mbxList ) {
      #  The user has supplied a list of mailboxes so only processes
      #  those
      @mbxs = split(/,/, $mbxList);
   }

   return @mbxs;
}


#  getDeletedMsgs
#
#  Get a list of deleted messages in the indicated mailbox on
#  the source host
#
sub getDeletedMsgs {

my $mailbox = shift;
my $msgs    = shift;
my $conn    = shift;
my $seen;
my $empty;
my $msgnum;

   &trim( *mailbox );
   &sendCommand ($conn, "$rsn SELECT \"$mailbox\"");
   undef @response;
   $empty=0;
   while ( 1 ) {
	&readResponse ( $conn );
	if ( $response =~ /^$rsn OK/i ) {
		# print STDERR "response $response\n";
		last;
        } elsif ( $response =~ / 0 EXISTS/i ) {
                $empty = 1;
	} elsif ( $response !~ /^\*/ ) {
		&Log ("unexpected response: $response");
		print STDERR "Error: $response\n";
		return 0;
	}
   }

   return if $empty;

   &sendCommand ( $conn, "$rsn FETCH 1:* (uid flags internaldate body[header.fields (Message-ID Subject)])");
   undef @response;
   while ( 1 ) {
	&readResponse ( $conn );
	if ( $response =~ /^$rsn OK/i ) {
		# print STDERR "response $response\n";
		last;
	}
        elsif ( $response =~ /Broken pipe|Connection reset by peer/i ) {
              print STDOUT "Fetch from $mailbox: $response\n";
              exit;
        }
   }

   #  Get a list of the msgs in the mailbox
   #
   undef @msgs;
   undef $flags;
   for $i (0 .. $#response) {
	$seen=0;
	$_ = $response[$i];

	last if /OK FETCH complete/;

	if ( $response[$i] =~ /FETCH \(UID / ) {
	   $response[$i] =~ /\* ([^FETCH \(UID]*)/;
	   $msgnum = $1;
	}

	if ($response[$i] =~ /FLAGS/) {
	    #  Get the list of flags
            $deleted = 0;
	    $response[$i] =~ /FLAGS \(([^\)]*)/;
	    $flags = $1;
            $deleted = 1 if $flags =~ /Deleted/i;
	}
        if ( $response[$i] =~ /INTERNALDATE ([^\)]*)/ ) {
	    $response[$i] =~ /INTERNALDATE ([^BODY]*)/i; 
            $date = $1;
            $date =~ s/"//g;
	}
        if ( $response[$i] =~ /^Subject:/ ) {
	   $response[$i] =~ /Subject: (.+)/;
           $subject = $1;
        }
	if ( $response[$i] =~ /^Message-Id:/ ) {
	    ($label,$msgid) = split(/: /, $response[$i]);
            &trim(*msgid);
            $msgid =~ s/^\<//;
            $msgid =~ s/\>$//;
            push( @$msgs, $msgnum ) if $deleted;
	}
   }
}


sub fetchMsg {

my $msgnum = shift;
my $mbx    = shift;
my $conn   = shift;
my $message;

   &Log("   Fetching msg $msgnum...") if $debug;
   &sendCommand ($conn, "$rsn SELECT \"$mbx\"");
   while (1) {
        &readResponse ($conn);
	last if ( $response =~ /^$rsn OK/i );
   }

   &sendCommand( $conn, "$rsn FETCH $msgnum (rfc822)");
   while (1) {
	&readResponse ($conn);
	if ( $response =~ /^$rsn OK/i ) {
		$size = length($message);
		last;
	} 
	elsif ($response =~ /message number out of range/i) {
		&Log ("Error fetching uid $uid: out of range",2);
		$stat=0;
		last;
	}
	elsif ($response =~ /Bogus sequence in FETCH/i) {
		&Log ("Error fetching uid $uid: Bogus sequence in FETCH",2);
		$stat=0;
		last;
	}
	elsif ( $response =~ /message could not be processed/i ) {
		&Log("Message could not be processed, skipping it ($user,msgnum $msgnum,$destMbx)");
		push(@errors,"Message could not be processed, skipping it ($user,msgnum $msgnum,$destMbx)");
		$stat=0;
		last;
	}
	elsif 
	   ($response =~ /^\*\s+$msgnum\s+FETCH\s+\(.*RFC822\s+\{[0-9]+\}/i) {
		($len) = ($response =~ /^\*\s+$msgnum\s+FETCH\s+\(.*RFC822\s+\{([0-9]+)\}/i);
		$cc = 0;
		$message = "";
		while ( $cc < $len ) {
			$n = 0;
			$n = read ($conn, $segment, $len - $cc);
			if ( $n == 0 ) {
				&Log ("unable to read $len bytes");
				return 0;
			}
			$message .= $segment;
			$cc += $n;
		}
	}
   }

   return $message;

}


sub usage {

   print STDOUT "usage:\n";
   print STDOUT " trash.pl -S sourceHost/sourceUser/sourcePassword\n";
   print STDOUT " Optional arguments:\n";
   print STDOUT "    -d debug\n";
   print STDOUT "    -t <trash mailbox name>\n";
   print STDOUT "    -e empty trash mailbox\n";
   print STDOUT "    -L <logfile>\n";
   print STDOUT "    -m <mailbox list> (eg \"Inbox, Drafts, Notes\". Default is all mailboxes)\n";
   exit;

}

sub processArgs {

   if ( !getopts( "dS:L:m:ht:e" ) ) {
      &usage();
   }

   ($sourceHost,$sourceUser,$sourcePwd) = split(/\//, $opt_S);
   $mbxList = $opt_m;
   $logfile = $opt_L;
   $trash   = $opt_t;
   $emptyTrash = 1 if $opt_e;
   $debug = $showIMAP = 1 if $opt_d;

   &usage() if $opt_h;
   $trash = 'Trash' if !$trash;

}

sub findMsg {

my $conn  = shift;
my $msgid = shift;
my $mbx   = shift;
my $msgnum;

   &Log("SELECT $mbx") if $debug;
   &sendCommand ( $conn, "1 SELECT \"$mbx\"");
   while (1) {
	&readResponse ($conn);
	last if $response =~ /^1 OK/;
   }

   &Log("Search for $msgid") if $debug;
   &sendCommand ( $conn, "$rsn SEARCH header Message-Id \"$msgid\"");
   while (1) {
	&readResponse ($conn);
	if ( $response =~ /\* SEARCH /i ) {
	   ($dmy, $msgnum) = split(/\* SEARCH /i, $response);
	   ($msgnum) = split(/ /, $msgnum);
	}

	last if $response =~ /^1 OK/;
	last if $response =~ /complete/i;
   }

   return $msgnum;
}

sub deleteMsg {

my $conn   = shift;
my $mbx    = shift;
my $msgnum = shift;
my $rc;

   &sendCommand ( $conn, "1 STORE $msgnum +FLAGS (\\Deleted)");
   while (1) {
        &readResponse ($conn);
        if ( $response =~ /^1 OK/i ) {
	   $rc = 1;
	   &Log("      Marked msg number $msgnum for delete");
	   last;
	}

	if ( $response =~ /^1 BAD|^1 NO/i ) {
	   &Log("Error setting \Deleted flag for msg $msgnum: $response");
	   $rc = 0;
	   last;
	}
   }

   return $rc;

}

sub expungeMbx {

my $mbx   = shift;
my $conn  = shift;

   print STDOUT "Purging mailbox $mbx..." if $debug;

   &sendCommand ($conn, "$rsn SELECT \"$mbx\"");
   while (1) {
        &readResponse ($conn);
        last if ( $response =~ /^$rsn OK/i );
   }

   &sendCommand ( $conn, "1 EXPUNGE");
   $expunged=0;
   while (1) {
        &readResponse ($conn);
        $expunged++ if $response =~ /\* (.+) Expunge/i;
        last if $response =~ /^1 OK/;

	if ( $response =~ /^1 BAD|^1 NO/i ) {
	   print "Error purging messages: $response\n";
	   last;
	}
   }

   $totalExpunged += $expunged;

   # print STDOUT "$expunged messages purged\n" if $debug;

}

sub checkForAdds {

my $added=0;

   &Log("Checking for messages to add to $destHost/$destUser");
   foreach $key ( @sourcekeys ) {
        if ( $destList{"$key"} eq '' ) {
             $entry = $sourceList{"$key"};
             ($msgid,$mbx) = split(/\|\|\|\|\|\|/, $key);
             ($msgnum,$flags,$date) = split(/\|\|\|\|\|\|/, $entry);
             &Log("   Adding $msgid to $mbx");

             #  Need to add this message to the dest host

             $message = &fetchMsg( $msgnum, $mbx, 'SRC' );

             &insertMsg( 'DST', $mbx, *message, $flags, $date );
             $added++;
        }
   }
   return $added;

}


sub checkForUpdates {

my $updated=0;

   #  Compare the flags for the message on the source with the
   #  one on the dest.  Update the dest flags if they are different

   &Log("Checking for flag changes to $destHost/$destUser");
   foreach $key ( @sourcekeys ) {
        $entry = $sourceList{"$key"};
        ($msgid,$mbx) = split(/\|\|\|\|\|\|/, $key);
        ($msgnum,$srcflags,$date) = split(/\|\|\|\|\|\|/, $entry);

        if ( $destList{"$key"} ne '' ) {
             $entry = $destList{"$key"};
             ($msgid,$mbx) = split(/\|\|\|\|\|\|/, $key);
             ($msgnum,$dstflags,$date) = split(/\|\|\|\|\|\|/, $entry);

	     $srcflags  =~ s/\\Recent//;
	     $destflags =~ s/\\Recent//;
	     if ( $srcflags ne $dstflags ) {
		&Log("Need to update the flags for $msgid") if $debug;
		$updated++ if &updateFlags( 'DST', $msgid, $mbx, $srcflags );
	     }
	}
   }
   return $updated;
}

sub updateFlags {

my $conn  = shift;
my $msgid = shift;
my $mbx   = shift;
my $flags = shift;
my $rc;

   if ( $debug ) {
      &Log("Find $msgid");
      &Log("flags $flags");
   }

   $msgnum = &findMsg( $conn, $msgid, $mbx );
   &Log("msgnum is $msgnum") if $debug;

   &sendCommand ( $conn, "1 STORE $msgnum +FLAGS ($flags)");
   while (1) {
        &readResponse ($conn);
        if ( $response =~ /^1 OK/i ) {
	   &Log("   Updated flags for $msgid");
	   $rc = 1;
	   last;
	}

        if ( $response =~ /^1 BAD|^1 NO/i ) {
           &Log("Error setting flags for $msgid: $response");
	   $rc = 0;
           last;
        }
   }
   return $rc;
}

sub dieright {
   local($sig) = @_;
   print STDOUT "caught signal $sig\n";
   &logout( 'SRC' );
   exit(-1);
}

sub sigprc {

   $SIG{'HUP'} = 'dieright';
   $SIG{'INT'} = 'dieright';
   $SIG{'QUIT'} = 'dieright';
   $SIG{'ILL'} = 'dieright';
   $SIG{'TRAP'} = 'dieright';
   $SIG{'IOT'} = 'dieright';
   $SIG{'EMT'} = 'dieright';
   $SIG{'FPE'} = 'dieright';
   $SIG{'BUS'} = 'dieright';
   $SIG{'SEGV'} = 'dieright';
   $SIG{'SYS'} = 'dieright';
   $SIG{'PIPE'} = 'dieright';
   $SIG{'ALRM'} = 'dieright';
   $SIG{'TERM'} = 'dieright';
   $SIG{'URG'} = 'dieright';
}

sub moveToTrash {

my $mbx   = shift;
my $trash = shift;
my $msgs  = shift;
my $conn  = shift;
my $msglist;
my $moved;

   return if $mbx eq $trash;
   return if $#$msgs == -1;

   foreach $msgnum ( @$msgs ) {
      $moved++;
      $msglist .= "$msgnum,";
   }

   chop $msglist;

   &sendCommand ($conn, "1 COPY $msglist $trash");
   while (1) {
        &readResponse ( $conn );
        last if $response =~ /^1 OK/i;
        if ($response =~ /NO/) {
           print STDOUT "unexpected COPY response: $response\n";
           print STDOUT "Please verify that mailbox $trash exists\n";
           exit;
        }
   }
   print STDOUT "   Moved $moved messages from $mbx to $trash\n";
   $total += $moved;

}
