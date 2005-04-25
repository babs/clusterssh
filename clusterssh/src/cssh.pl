# -* perl *-
# $Id$
#
# Script:
#   $RCSfile$
#
# Usage:
#   cssh [options] [hostnames] [...]
#
# Options:
#   see pod documentation
#
# Parameters:
#   hosts to open connection to
#
# Purpose:
#   Concurrently administer multiple remote servers
#
# Dependencies:
#   Perl 5.6.0
#   Tk 800.022
#
# Limitations:
#
# Enhancements:
#
# Notes:
#
# License:
#   This code is distributed under the terms of the GPL (GNU General Pulic
#   License).
#
#   Copyright (C)
#
#   This program is free software; you can redistribute it and/or modify it
#   under the terms of the GNU General Public License as published by the
#   Free Software Foundation; either version 2 of the License, or any later
#   version.
#
#   This program is distributed in the hope that it will be useful, but
#   WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General
#   Public License for more details.
#
#   You should have received a copy of the GNU General Public License along
#   with this program; if not, write to the Free Software Foundation, Inc.,
#   59 Temple Place, Suite 330, Boston, MA 02111-1307 USA
#
#   Please see the full text of the licenses is in the file COPYING and also at
#     http://www.opensource.org/licenses/gpl-license.php
#
############################################################################
my $VERSION='$Revision$ ($Date$)';
# Now tidy it up, but in such as way cvs doesn't kill the tidy up stuff
$VERSION=~s/\$Revision: //;
$VERSION=~s/\$Date: //;
$VERSION=~s/ \$//g;

### all use statements ###
use strict;
use warnings;

use 5.006_000;
use Pod::Usage;
use Getopt::Std;
use POSIX qw/strftime mkfifo :sys_wait_h/;
use File::Temp qw/:POSIX/;
use Fcntl;
use Tk 800.022;
use Tk::Xlib;
require Tk::Dialog;
require Tk::LabEntry;
use X11::Protocol;
use vars qw/ %keysymtocode /;
use X11::Keysyms '%keysymtocode';
#use FindBin; # used to get full path to this script
use File::Basename;

### all global variables ###
my $scriptname=$0; $scriptname=~ s!.*/!!; # get the script name, minus the path

my $options='dDv?hHuqQt:'; # Command line options list
my %options;
my %config;
my $debug=0;
my %clusters; # hash for resolving cluster names
my %windows; # hash for all window definitions
my %menus; # hash for all menu definitions
my @servers; # array of servers provided on cmdline
my %servers; # hash of server cx info
my $helper_script;
my $xdisplay=X11::Protocol->new();
my %keycodes;

my %chartokeysym = (
	'!' => 'exclam',
	'"' => 'quotedbl',
	'\uffff' => 'sterling',
	'$' => 'dollar',
	'%' => 'percent',
	'^' => 'asciicircum',
	'&' => 'ampersand',
	'*' => 'asterisk',
	'(' => 'parenleft',
	')' => 'parenright',
	'_' => 'underscore',
	'+' => 'plus',
	'-' => 'minus',
	'=' => 'equal',
	'{' => 'braceleft',
	'}' => 'braceright',
	'[' => 'bracketleft',
	']' => 'bracketright',
	':' => 'colon',
	'@' => 'at',
	'~' => 'asciitilde',
	';' => 'semicolon',
	"\'" => 'apostrophe',
	'#' => 'numbersign',
	'<' => 'less',
	'>' => 'greater',
	'?' => 'question',
	',' => 'comma',
	'.' => 'period',
	'/' => 'slash',
	"\\" => 'backslash',
	'|' => 'bar',
	'`' => 'grave',
	' ' => 'space',
);

### all sub-routines ###

# catch_all exit routine that should always be used
sub exit_prog()
{
	logmsg(3, "Exiting via normal routine");
	# for each of the client windows, send a kill

	# to make sure we catch all children, even when they havnt
	# finished starting or received teh kill signal, do it like this
	while (%servers)
	{
		foreach my $svr (keys(%servers))
		{
			kill(9, $servers{$svr}{pid}) if kill(0, $servers{$svr}{pid});
			delete($servers{$svr});
		}
	}
	exit 0;
}

# output function according to debug level
# $1 = log level (0 to 3)
# $2 .. $n = list to pass to print
sub logmsg($@)
{
	my $level=shift;

	if($level <= $debug)
	{
		print @_,$/;
	}
}

# set some application defaults
sub load_config_defaults()
{
	$config{terminal}="xterm";
	$config{terminal_args}="";
	$config{terminal_title_opt}="-T";
	$config{terminal_allow_send_events}="-xrm 'XTerm.VT100.allowSendEvents:true'";
	$config{user}=$ENV{LOGNAME};
	$config{use_hotkeys}="yes";
	$config{key_quit}="Control-q";
	$config{key_addhost}="Control-plus";
	$config{key_clientname}="Alt-n";
	$config{reserve_top}=50;
	$config{reserve_bottom}=0;
	$config{reserve_left}=0;
	$config{reserve_right}=0;
	$config{auto_quit}="yes";

	($config{comms}=basename($0)) =~ s/^.//;
	$config{$config{comms}}=$config{comms};

	$config{ssh_args}.="-x" if ($config{$config{comms}} =~ /ssh$/);
	$config{rsh_args}="";

	$config{title}="CSSH";
}

# load in config file settings
sub load_configfile($)
{
	my $config_file=shift;
	logmsg(2,"Reading in from config file $config_file");
	return if (! -f $config_file);

	open(CFG, $config_file) or die("Couldnt open $config_file: $!");;
	while(<CFG>)
	{
		next if(/^\s*$/ || /^#/); # ignore blank lines & commented lines
		s/#.*//; # remove comments from remaining lines
		chomp();
		my ($key, $value) = split(/[ 	]*=[ 	]*/);
		$config{$key} = $value;
		logmsg(3,"$key=$value");
	}
	close(CFG);
}

sub find_binary($)
{
	my $binary=shift;

	logmsg(3,"Looking for $binary");
	my $path=`which $binary 2>/dev/null`;
	if(!$path)
	{
		die("$binary not found - please amend \$PATH or the cssh config file\n");
	} 
	chomp($path);
	return $path;
}

# make sure our config is sane (i.e. binaries found)
sub check_config()
{
	# check we have xterm on our path
	logmsg(2, "Checking path to xterm");
	$config{terminal}=find_binary($config{terminal});

	# check we have comms method on our path
	logmsg(2, "Checking path to $config{comms}");
	$config{$config{comms}}=find_binary($config{comms});

	# make sure comms in an accepted value
	die "FATAL: Only ssh and rsh protocols are currently supported (comms=$config{comms})\n" if($config{comms} !~ /^[rs]sh$/);

	# Set any extra config options given on command line
	$config{title}=$options{t} if($options{t});

	$config{auto_quit}="yes" if $options{q};
	$config{auto_quit}="no" if $options{Q};
}

# dump out the config to STDOUT
sub dump_config()
{
	logmsg(3, "Dumping config to STDOUT");

	print("# Configuration dump produced by 'cssh -u'\n");

	foreach (sort(keys(%config)))
	{
		next if($_ =~ /^internal/); # do not output internal vars
		print "$_=$config{$_}\n";
	}
	exit_prog;
}

sub load_keyboard_map()
{
	# load up the keyboard map to convert keysyms to keycodes
	my $min=$xdisplay->{min_keycode};
	my $count=$xdisplay->{max_keycode} - $min;
	my @keyboard=$xdisplay->GetKeyboardMapping($min, $count);

	foreach (0 .. $#keyboard)
	{
		$keycodes{$keyboard[$_][0]}=$_+$min;
		$keycodes{$keyboard[$_][1]}=$_+$min;
	}
}

# read in all cluster definitions
sub get_clusters()
{
	# first, read in global file
	my $cluster_file='/etc/clusters';

	logmsg(3, "Looging for $cluster_file");

	if(-f $cluster_file)
	{
		logmsg(2,"Loading clusters in from $cluster_file");
		open(CLUSTERS, $cluster_file) || die("Couldnt read $cluster_file");
		while(<CLUSTERS>)
		{
			next if(/^\s*$/ || /^#/); # ignore blank lines & commented lines
			chomp();
			s/^([\w-]+)\s*//; # remote first word and stick into $1
			logmsg(3,"cluster $1 = $_");
			$clusters{$1} = $_ ; # Now bung in rest of line
		}
		close(CLUSTERS);
	}

	# Now get any definitions out of %config
	logmsg(2,"Looking for user space clusters");
	if($config{clusters})
	{
		logmsg(2,"Loading clusters in from user space");

		foreach (split(/\s+/, $config{clusters}))
		{
			logmsg(3,"cluster $_ = $config{$_}");
			$clusters{$_} = $config{$_};
		}
	}
}

sub resolve_names(@)
{
	my @servers=@_;

	foreach (@servers)
	{
		logmsg(3, "Found server $_");

		if($clusters{$_})
		{
			push(@servers, split(/ /, $clusters{$_}));
			$_="";
		}
	}

	my @cleanarray;

	# now clean the array up
	foreach (@servers)
	{
		push(@cleanarray, $_) if($_ !~ /^$/);
	}

	foreach (@cleanarray)
	{
		logmsg(3, "leaving with $_");
	}
	return(@cleanarray);
}

sub change_main_window_title()
{
	my $number=keys(%servers);
	$windows{main_window}->title($config{title}." [$number]");
}

sub send_text($@)
{
	my $svr=shift;
	my $text=join("", @_);

	logmsg(2, "Sending to $svr text:$text:");

	logmsg(2, "servers{$svr}{wid}=$servers{$svr}{wid}");

	# work out whether or nto we also need to send a newline, which isnt
	# in the keysym hash
	my $newline=chomp($text);

#	if($newline =~ /\\x{a}$/)
#	{
#		$newline=1;
#		$newline =~ s/\\x{a}$//;
#	}

	foreach my $char (split(//, $text) , ($newline ? "Return" : ""))
	{
		my $code;
		if(exists($chartokeysym{$char}))
		{
			$code=$chartokeysym{$char};
		} else {
			$code=$char;
		}

		#if ($chartokeysym{$char})
		#{
			#$code=$chartokeysym{$char};
		#} else {
			#$code=$keycodes{$keysymtocode{$char}};
		#}

		logmsg(2, "char=:$char: code=:$code: number=:$keycodes{$keysymtocode{$code}}:");
		#logmsg(2, "char=:$char:");

		for my $event (qw/KeyPress KeyRelease/)
		{
			logmsg(2, "event=$event");
			$xdisplay->SendEvent($servers{$svr}{wid}, 0,
				$xdisplay->pack_event_mask($event),
				$xdisplay->pack_event(
					'name' => $event,
					'detail' => $keycodes{$keysymtocode{$code}},
					'state' => 0,
					'time' => time(),
					'event' => $servers{$svr}{wid},
					'root' => $xdisplay->root(),
					'same_screen' => 1,
				),
			);
		}
	}
	$xdisplay->flush();
}

sub send_clientname()
{
	foreach my $svr (keys(%servers))
	{
		send_text($svr, $svr."\n");
#		foreach my $char (split(//, $servers{$svr}{realname}), "Return")
#		{
#			$xdisplay->SendEvent($servers{$svr}{wid}, 0, 
#				$xdisplay->pack_event_mask("KeyPress"),
#				$xdisplay->pack_event(
#					'name' => "KeyPress",
#					'detail' => $keycodes{$keysymtocode{$char}},
#					'state' => 0,
#					'time' => time(),
#					'event' => $servers{$svr}{wid}, 
#					'root' => $xdisplay->root(), 
#					'same_screen' => 1,
#				)
#			);
#			$xdisplay->flush();
#
#			$xdisplay->SendEvent($servers{$svr}{wid}, 0, 
#				$xdisplay->pack_event_mask("KeyRelease"),
#				$xdisplay->pack_event(
#					'name' => "KeyRelease",
#					'detail' => $keycodes{$keysymtocode{$char}},
#					'state' => 0,
#					'time' => time(),
#					'event' => $servers{$svr}{wid}, 
#					'root' => $xdisplay->root(), 
#					'same_screen' => 1,
#				)
#			);
#			$xdisplay->flush();
#		}
	}
}

sub setup_helper_script()
{
	$helper_script=<<"	HERE";
		my \$pipe=shift;
		my \$svr=shift;
		open(PIPE, ">", \$pipe);
		print PIPE "\$ENV{WINDOWID}";
		close(PIPE);
		exec("$config{$config{comms}} $config{$config{comms}."_args"} \$svr");
	HERE
}

sub open_client_windows(@)
{
	foreach (@_)
	{
		next unless($_);

		my $count = 1;
		my $server=$_;

		while(defined($servers{$server}))
		{
			$server=$_." ".$count++;
		}

		$servers{$server}{realname}=$_;

		#print "Finished with $server for $_\n";

		$servers{$server}{pipenm}=tmpnam();
		#print "tmpnam=$servers{$server}{pipenm}\n";
		mkfifo($servers{$server}{pipenm}, 0600) or die("Cannot create pipe: $!");

		#print "fifo made\n";
		#print "Helper: $helper_script\n";

		$servers{$server}{pid}=fork();
		if(!defined($servers{$server}{pid}))
		{
			die("Could not fork: $!");
		}


		if($servers{$server}{pid}==0)
		{
			my $exec="$config{terminal} $config{terminal_args} $config{terminal_allow_send_events} $config{terminal_title_opt} '$config{title}:$server' -e $^X -e '$helper_script' $servers{$server}{pipenm} $servers{$server}{realname}";
			# this is the child
			my $copy=$exec;
			$copy =~ s/-e.*/-e 'echo Working - waiting 10 seconds;sleep 10;exit'/s;
			logmsg(1,"$copy\n");
			exec($exec) == 0 or warn("Failed: $!");;
		}

		# block on open so we get the text when it comes in
		if(!sysopen($servers{$server}{pipehl}, $servers{$server}{pipenm}, O_RDONLY))
		{
			unlink($servers{$server}{pipenm});
			die ("Cannot open pipe for writing: $!");
		}

		sysread($servers{$server}{pipehl}, $servers{$server}{wid}, 100);
		close($servers{$server}{pipehl});
		delete($servers{$server}{pipehl});

		unlink($servers{$server}{pipenm});
		delete($servers{$server}{pipenm});

		$servers{$server}{active}=1; # mark as active
		$config{internal_activate_autoquit}=1 ; # activate auto_quit if in use
	}
}

sub add_host_by_name()
{
	logmsg(2, "Adding host to menu here");

	$windows{host_entry}->focus();
	my $answer=$windows{addhost}->Show();

	if($answer ne "Add")
	{
		$menus{host_entry}="";
		return;
	}

	logmsg(2, "host=$menus{host_entry}");

	open_client_windows( $menus{host_entry} );
	build_hosts_menu();
	$menus{host_entry}="";
	select(undef,undef,undef,0.25); #sleep for a mo
	$windows{main_window}->withdraw;
	$windows{main_window}->deiconify;
	$windows{main_window}->raise;
	$windows{main_window}->focus;
	$windows{text_entry}->focus();
}

sub build_hosts_menu()
{
	# first, emtpy the hosts menu from the 2nd entry on
	my $menu=$menus{bar}->entrycget('Hosts', -menu);
	$menu->delete(2,'end');

	# add back the seperator
	$menus{hosts}->separator;

	foreach my $svr (sort(keys(%servers)))
	{
		$menus{hosts}->checkbutton(
			-label=>$svr,
			-variable=>\$servers{$svr}{active},
		);
	}
	change_main_window_title();
}

sub setup_repeat()
{
	$windows{main_window}->repeat(500, sub {
		my $build_menu=0;
		foreach my $svr (keys(%servers))
		{
			if(! kill(0, $servers{$svr}{pid}) )
			{
				$build_menu=1;
				delete($servers{$svr});
			}
		}

		build_hosts_menu() if($build_menu);

		# If there are no hosts in the list and we are set to autoquit
		if(scalar(keys(%servers)) == 0 && $config{auto_quit}=~/yes/i)
		{
			# and some clients were actually opened...
			if($config{internal_activate_autoquit})
			{	
				exit_prog;
			}
		}
		$menus{entrytext}="";
	});
}

### Window and menu definitions ###

sub create_windows()
{
	$windows{main_window}=MainWindow->new(-title=>"ClusterSSH");

	$menus{entrytext}="";
	$windows{text_entry}=$windows{main_window}->Entry(
		-textvariable  =>  \$menus{entrytext},
		-insertborderwidth            => 4,
		-width => 25,
	)->pack( 
		-fill => "x",
		-expand => 1,
	);

	# grab paste events into the text entry
	$windows{main_window}->eventAdd('<<Paste>>' => '<Control-v>');
	$windows{main_window}->eventAdd('<<Paste>>' => '<Button-2>');

	$windows{main_window}->bind('<<Paste>>' => sub {
		$menus{entrytext}="";
		my $paste_text = '';
		# SelectionGet is fatal if no selection is given
		Tk::catch { $paste_text=$windows{main_window}->SelectionGet };

		# now sent it on
		foreach my $svr (keys(%servers))
		{
			send_text($svr, $paste_text);
		}
	});

	$windows{help}=$windows{main_window}->Dialog(
		-popover      => $windows{main_window},
		-overanchor   => "c",
		-popanchor    => "c",
		-font         => [
			-family => "interface system",
			-size   => 10,
		],
		-text => "Cluster Administrator Console using SSH\n\nVersion: $VERSION.\n\n" .
		"Bug/Suggestions to http://clusterssh.sf.net/",
	);

	$windows{manpage}=$windows{main_window}->DialogBox(
		-popanchor    => "c",
		-overanchor   => "c",
		-title        => "Cssh Documentation",
		-buttons      => [ 'Close' ],
	);

	my $manpage=`pod2text -l -q=\"\" $0`;
	$windows{mantext}=$windows{manpage}->Scrolled("Text",)->pack(-fill=>'both');
	$windows{mantext}->insert('end', $manpage);
	$windows{mantext}->configure(-state=>'disabled');

	$windows{addhost}= $windows{main_window}->DialogBox(
		-popover        => $windows{main_window},
		-popanchor      => 'n',
		-title          => "Add Host",
		-buttons        => [ 'Add', 'Cancel' ],
		-default_button => 'Add',
	);

	$windows{host_entry} = $windows{addhost} -> add('LabEntry',
		-textvariable    => \$menus{host_entry},
		-width           => 20,
		-label           => 'Host',
		-labelPack       => [ -side => 'left', ],
	)->pack(-side=>'left');
}

# for all key event, event hotkeys so there is only 1 key binding
sub key_event {
	my $event=$Tk::event->T;
	my $keycode=$Tk::event->k;
	my $keynum=$Tk::event->N;
	my $keysym=$Tk::event->K;
	my $state=$Tk::event->s;
	$menus{entrytext}="";

	logmsg(2, "event=$event");
	logmsg(2, "sym=$keysym (state=$state)");
	if($config{use_hotkeys} eq "yes")
	{
		my $combo=$Tk::event->s."-".$Tk::event->K;

		foreach my $hotkey (grep(/key_/, keys(%config)))
		{
			#print "Checking hotkey $hotkey ($config{$hotkey})\n";
			my $key=$config{$hotkey};
			$key =~ s/-/.*/g;
			#print "key=$key\n";
			#print "combo=$combo\n";
			if($combo =~ /$key/)
			{
				if($event eq "KeyRelease")
				{
					#print "FOUND for $hotkey!\n";
					send_clientname() if($hotkey eq "key_clientname");
					add_host_by_name() if($hotkey eq "key_addhost");
					exit_prog() if($hotkey eq "key_quit");
				}
				return;
			}
		}
	}

	# look for a <Control>-d and no hosts, so quit
	exit_prog() if($state =~ /Control/ && $keysym eq "d" and !%servers);

	# for all servers
	foreach (keys(%servers))
	{
		# if active
		if($servers{$_}{active} == 1)
		{
			logmsg(3, "Sending event $event with code $keycode to window $servers{$_}{wid}");
			logmsg(3, "event:",$event);
			logmsg(3, "root:",$servers{$_}{wid});
			logmsg(3, "detail:",$keycode);

			$xdisplay->SendEvent($servers{$_}{wid}, 0, 
				$xdisplay->pack_event_mask($event),
				$xdisplay->pack_event(
					'name' => $event,
					'detail' => $keycode,
					'state' => $state,
					'time' => time(),
					'event' => $servers{$_}{wid}, 
					'root' => $xdisplay->root(), 
					'same_screen' => 1,
				)
			);
		}
	}
	$xdisplay->flush();
}

sub create_menubar()
{
	$menus{bar}=$windows{main_window}->Menu;
	$windows{main_window}->configure(-menu=>$menus{bar}); 

	$menus{file}=$menus{bar}->cascade(
		-label     => '~File',
		-menuitems => [
			[ 
				"command", 
				"Exit", 
				-command => \&exit_prog, 
				-accelerator => $config{key_quit},
			]
		],
		-tearoff   => 0,
	);

	$menus{hosts}=$menus{bar}->cascade(
		-label     => 'H~osts',
		-tearoff   => 1,
		-menuitems => [
			[
				 "command",
				 "Add Host",
				 -command     => \&add_host_by_name,
				 -accelerator => $config{key_addhost},
			],
			'',
		],
	);

	$menus{send}=$menus{bar}->cascade(
		-label     => '~Send',
		-menuitems => [
			[
				"command", 
				"Hostname",
				-command     => \&send_clientname,
				-accelerator => $config{key_clientname},
			],
		],
		-tearoff   => 1,
	);

	$menus{help}=$menus{bar}->cascade(
		-label     => '~Help',
		-menuitems => [
			[
				'command',
				"About",
				-command=> sub { $windows{help}->Show } 
			],[
				'command',
				"Documentation",
				-command=> sub { $windows{manpage}->Show}
			],
		],
		-tearoff   => 0,
	);

	#$windows{main_window}->bind(
		#'<Key>' => \&key_event,
	#);
	$windows{main_window}->bind(
		'<KeyPress>' => \&key_event,
	);
	$windows{main_window}->bind(
		'<KeyRelease>' => \&key_event,
	);
}

### main ###

# Note: getopts returned "" if it finds any options it doesnt recognise
# so use this to print out basic help
pod2usage(-verbose => 1) unless(getopts($options, \%options));
pod2usage(-verbose => 1) if($options{'?'} || $options{h});
pod2usage(-verbose => 2) if($options{H});

if($options{v}) {
	print "Version: $VERSION\n";
	exit 0;
}

# catch and reap any zombies
sub REAPER { 1 until waitpid(-1, WNOHANG) == -1 }
$SIG{CHLD} = \&REAPER;

$debug+=1 if($options{d});
$debug+=2 if($options{D});

load_config_defaults();
load_configfile('/etc/csshrc');
load_configfile($ENV{HOME}.'/.csshrc');
check_config();
dump_config() if($options{u});

load_keyboard_map();

get_clusters();

@servers = resolve_names(@ARGV);

create_windows();
create_menubar();

change_main_window_title();

setup_helper_script();
open_client_windows(@servers);

build_hosts_menu();

setup_repeat();

#print "$_ = $keysymtocode{$_}\n" foreach (keys(%keysymtocode));

#exit;

select(undef,undef,undef,0.25); #sleep for a mo
$windows{text_entry}->focus();
# Start even loop & open windows
MainLoop();

# make sure we leave program in an expected way
exit_prog;

__END__
# man/perldoc/pod page

=head1 NAME

cssh (crsh) - Cluster administration tool

=head1 SYNOPSIS

S<< cssh [-?hHvdDuqQ] [[user@]<server>|<tag>] [...] >>
S<< crsh [-?hHvdDuqQ] [[user@]<server>|<tag>] [...] >>

=head1 DESCRIPTION

The command opens an administration console and an xterm to all specified 
hosts.  Any text typed into the administration console is replicated to 
all windows.  All windows may also be typed into directly.

This tool is intended for (but not limited to) cluster administration where
the same configuration or commands must be run on each node within the
cluster.  Performing these commands all at once via this tool ensures all
nodes are kept in sync.

Connections are opened via ssh so a correctly installed and configured
ssh installation is required.  If, however, the program is called by "crsh"
then the rsh protocol is used (and the communcations channel is insecure).

Extra caution should be taken when editing system files such as
/etc/inet/hosts as lines may not necessarily be in the same order.  Assuming
line 5 is the same across all servers and modifying that is dangerous.
Better to search for the specific line to be changed and double-check before
changes are committed.

=head2 Further Notes

=over

=item *

The dotted line on any sub-menu is a tear-off, i.e. click on it
and the sub-menu is turned into its own window.

=item *

Unchecking a hostname on the Hosts sub-menu will unplug the host from the
cluster control window, so any text typed into the console is not sent to
that host.  Re-selecting it will plug it back in.

=item *

If the code is called as crsh instead of cssh (i.e. a symlink called
crsh points to the cssh file or the file is renamed) rsh is used as the
communcations protocol instead of ssh.

=back

=head1 OPTIONS

The following options are supported (some of these may also be defined
within the configuration files detailed below; the command line options take
precedence):

=over

=item -h|-?

Show basic help text, and exit

=item -H

Show full help test (the man page), and exit

=item -v

Show version information and exit

=item -d 

Enable basic debugging mode (can be combined with -D)

=item -D 

Enable extended debugging mode (can be combined with -d)

=item -q

Automatically quit after the last client window has closed

=item -Q

Disable auto_quit functionality (to allow for config file override)

=item -u

Output configuration in the format used by the F<$HOME/.csshrc> file

=back

=head1 ARGUMENTS

The following arguments are support:

=over

=item [usr@]<hostname> ...

Open an xterm to the given hostname and connect to the administration
console.

=item <tag> ...

Open a series of xterms defined by <tag> within either /etc/clusters or
F<$HOME/.csshrc> (see FILES).

=back

=head1 KEY SHORTCUTS

The following key shortcuts are available within the console window, and all
of them may be changed via the configuration files.

=over

=item Control-q

Quit the program and close all connections and windows

=item Control-+

Open the Add Host dialogue box

=item Alt-n

Paste in the correct client name to all clients, i.e.

C<< scp /etc/hosts server:files/<Alt-n>.hosts >>

would replace the <Alt-n> with the client's name in all the client windows

=back

=head1 FILES

=over

=item /etc/clusters

This file contains a list of tags to server names mappings.  When any name
is used on the command line it is checked to see if it is a tag in
/etc/clusters.  If it is a tag, then the tag is replaced with the list
of servers from the file.  The file is formated as follows:

S<< <tag> [user@]<server> [user@]<server> [...] >>

i.e.

S<< # List of servers in live >>
S<< live admin1@server1 admin2@server2 server3 server4 >>

All standard comments and blank lines are ignored.  Tags may be nested, but
be aware of recursive tags.

=item F</etc/csshrc> & F<$HOME/.csshrc>

This file contains configuration overrides - the defaults are as marked.
Default options are overwritten first by the global file, and then by the
user file.

=over

=item always_tile = yes

Setting to anything other than C<yes> does not perform window tiling (see also -G).

=item auto_quit = yes

Automatically quit after the last client window closes.  Set to anything
other than "yes" to disable.  Can be overridden by C<-Q> on the command line.

=item comms = ssh

Sets the default communication method (initially taken from the name of 
program, but can be overridden here).

=item ssh_args = -x & rsh_args = <blank>

Sets any arguments to be used with the communication method (defaults to ssh
arguments).

=item key_addhost = Control-plus

Default key sequence to open AddHost menu.  See below notes on shortcuts.

=item key_clientname = Alt-n

Default key sequence to send cssh client names to client.  See below notes 
on shortcuts.

=item key_quit = Control-q

Default key sequence to quit the program (will terminate all open windows).  
See below notes on shortcuts.

=item reserve_top = 50

=item reserve_bottom = 0

=item reserve_left = 0

=item reserve_right = 0

Number of pixels from the screen side to reserve when calculating screen 
geometry for tiling.  Setting this to something like 50 will help keep cssh 
from positioning windows over your window manager's menu bar if it draws one 
at that side of the screen.

=item ssh = /path/to/ssh

=item rsh = /path/to/rsh

Depending on the value of comms, set the path of the communication binary.

=item terminal = /path/to/terminal

Path to the x-windows terminal used for the client.

=item terminal_args = <blank>

Arguments to use when opening terminal windows.  Otherwise takes defaults
from F<$HOME/.Xdefaults> or $<$HOME/.Xresources> file.

=item terminal_title_opt = -T

Option used with C<terminal> to set the title of the window

=item terminal_allow_send_events = -xrm 'XTerm.VT100.allowSendEvents:true'

Option required by the terminal to allow XSendEvents to be received

=item title = cssh

Title of windows to use for both the console and terminals.

=item use_hotkeys = yes

Setting to anything other than C<yes> will disable all hotkeys.

=item user = $LOGNAME

Sets the default user for running commands on clients.

=back

NOTE: The key shortcut modifiers must be in the form "Control", "Alt", or 
"Shift", i.e. with the first letter capitalised and the rest lower case.

=back

=head1 AUTHOR

Duncan Ferguson

=head1 CREDITS

clusterssh is distributed under the GNU public license.  See the file
F<LICENSE> for details.

A web site for comments, requests, bug reports and bug fixes/patches is
available at L<http://clusterssh.sourceforge.net/>

=head1 KNOWN BUGS

None are known at this time

=head1 REPORTING BUGS

=over 2

=item *

If you require support, please run the following commands
and post it on the web site in the support/problems forum:

C<< perl -V >>

C<< perl -MTk -e 'print $Tk::VERSION,$/' >>

C<< perl -MX11::Protocol -e 'print $X11::Protocol::VERSION,$/' >>

=item *

Use the debug switches (-d, -D, or -dD) will turn on debugging output.  
However, please only use this option with one host at a time, 
i.e. "cssh -d <host>" due to the amount of output produced (in both main 
and child windows).

=back

=head1 SEE ALSO

L<http://clusterssh.sourceforge.net/>,
L<ssh>,
L<Tk::overview>,
L<X11::Protocol>,
L<perl>

=cut
