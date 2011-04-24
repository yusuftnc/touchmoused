#!/usr/bin/perl

my $name = `hostname`;

use IO::Select;
use IO::Socket;
use IO::Handle; # Needed for autoflush
use Fcntl; # Needed for sysopen flags (?)
use POSIX ":sys_wait_h";

use constant {
	UI_DEV_CREATE => 0x5501,
	UI_DEV_DESTROY => 0x5502,
	
	UI_SET_EVBIT => 0x40045564,
	UI_SET_KEYBIT => 0x40045565,
	UI_SET_RELBIT => 0x40045566,
	UI_SET_ABSBIT => 0x40045567,

	EV_SYN => 0x00,
	EV_KEY => 0x01,
	EV_REL => 0x02,
	EV_ABS => 0x03,

	REL_X => 0x00,
	REL_Y => 0x01,

	ABS_X => 0x00,
	ABS_Y => 0x01,

	BUS_USB => 0x03,

	BTN_MOUSE => 0x110,
	BTN_TOUCH => 0x14a,
	BTN_TOOL_FINGER => 0x145,

	SYN_REPORT => 0,
};

my %keymap = (
	ord('1') => 2,
	ord('2') => 3,
	ord('3') => 4,
	ord('4') => 5,
	ord('5') => 6,
	ord('6') => 7,
	ord('7') => 8,
	ord('8') => 9,
	ord('9') => 10,
	ord('0') => 11,
	ord('-') => 12,
	ord('=') => 13,
	'bkspc' => 14,

	ord('q') => 16,
	ord('w') => 17,
	ord('e') => 18,
	ord('r') => 19,
	ord('t') => 20,
	ord('y') => 21,
	ord('u') => 22,
	ord('i') => 23,
	ord('o') => 24,
	ord('p') => 25,

	ord('a') => 30,
	ord('s') => 31,
	ord('d') => 32,
	ord('f') => 33,
	ord('g') => 34,
	ord('h') => 35,
	ord('j') => 36,
	ord('k') => 37,
	ord('l') => 38,
	
	ord('z') => 44,
	ord('m') => 50,
);

require "sys/ioctl.ph";

chomp $name;

my $avahi_publish = fork();
if ($avahi_publish==0) {
	exec 'avahi-publish-service',
		$name,
		"_iTouch._tcp",
		"4026";
}

sub REAP {
    if ($avahi_publish == waitpid(-1, WNOHANG)) {
        die("Avahi publishing failed!");
    }
    printf("***CHILD EXITED***\n");
    $SIG{CHLD} = \&REAP;
};
$SIG{CHLD} = \&REAP;

my %conns;

my $ui;
sysopen($ui, '/dev/uinput', O_NONBLOCK|O_WRONLY) || die "Can't open /dev/uinput: $!"; 
$ui->autoflush(1);

# uinput_user_dev:
# char name[80]
# struct input_id
# int ff_effects_max;
# int absmax[ABS_MAX + 1]
# int absmin[ABS_MAX + 1]
# int absfuzz[ABS_MAX + 1]
# int absflat[ABS_MAX + 1]

# input_id:
# _u16 bustype
# _u16 vendor
# _u16 product
# _u16 version

# input_event
# struct timeval time;
# _u16 type
# _u16 code
# _s32 value

# timeval
# __kernel_time_t tv_sec (int)
# __kernel_suseconds_t tv_usec (int)

my $strpk_uinput_dev = "a80SSSSiI256";
my $strpk_input_event = "LLSSL";

my $ret;
$ret = ioctl($ui, UI_SET_EVBIT, EV_KEY) || -1;
print "UI_SET_EVBIT EV_KEY: $ret\n";

$ret = ioctl($ui, UI_SET_EVBIT, EV_SYN) || -1;
print "UI_SET_EVBIT EV_SYN: $ret\n";

for my $key ( values %keymap ) {
	$ret = ioctl($ui, UI_SET_KEYBIT, $key) || -1;
	print "UI_SET_KEYBIT $key: $ret\n";
}

my @abs;
foreach (1..256) {
	# We're not using absolute mouse-events
	push(@abs, 0x00);
}

print $ui pack($strpk_uinput_dev, "TouchMouse", BUS_USB, 0x1234, 0xfedc, 1, 0, @abs);

$ret = ioctl($ui, UI_DEV_CREATE, 0) || -1;
print "UI_DEV_CREATE: $ret \n";
if (-1 == $ret) {
	die("device creation failed");
}

my $listen = new IO::Socket::INET(Listen => 1,
	LocalPort => 4026,
	ReuseAddr => 1,
	Proto => 'tcp') or die "Can't listen on port 4026: $!";

my $sel = new IO::Select($listen);

print "listening...\n";

while (1) {
	my @waiting = $sel->can_read;
	foreach $fh (@waiting) {
		if ($fh==$listen) {
			my $new = $listen->accept;
			printf "new connection from %s\n", $new->sockhost;

			$sel->add($new);
			$new->blocking(0);
			$conns{$new} = {fh => $fh};

			print "Creating UDP socket\n";
			my $sock = IO::Socket::INET->new(LocalPort => 4026, Proto => 'udp') or die ("Couldn't create UDP socket: $!");
			my $message;
			
			while ($sock->recv($message, 1024)) {
				printf "UDP Received: %s\n", unpack("H*", $message);
				
				my($type, $value, $other) = unpack("NNN", $message);
				
				if ($type==13) {
					print "Key pressed\n";
					# A = 30

					if ($keymap{$value}) {
						print $ui pack($strpk_input_event, 0, 0, EV_KEY, $keymap{$value}, 1);
						print $ui pack($strpk_input_event, 0, 0, EV_KEY, $keymap{$value}, 0);
						print $ui pack($strpk_input_event, 0, 0, EV_SYN, 0, 0);
					}
				}

				#printf "$type $value $other\n";
				#my($pre, $ord, $post) = unpack("H12H4H*", $message);
				#printf "Pre: $pre Ord: $ord Char: %s Post: $post\n", pack("H*", $ord);
			}
		} else {
			if (eof($fh)) {
				print "closed: $fh\n";
				$sel->remove($fh);
				close $fh;
				delete $conns{$fh};
				next;
			}
			if (exists $conns{$fh}) {
				conn_handle_data($fh);
			}
		}
	}
}

# events
# LMB_D:	00000005000001000000006c2fa30ca1
# LMB_U:	00000004000001000000006c31872e21
# RMB_D:	0000000500000101000000ff189058be
# RMB_U:	0000000400000101000000ff1b671f6e
# MMB_D:	00000005000001020000012733f02ab1
# MMB_U:	0000000400000102000001281e7873b3
# a:		0000000d00000061135cbb3c08670807
# z:		0000000d0000007a135cbb5426d4951c
# A:		0000000d00000041135cbb7711e1220e
# Z:		0000000d0000005a135cbb870e57054f
# á:		0000000d000000e1135cbf511b2eb996
# ¥:		0000000d000000a5135cbfe71b89b6a9
# €:		0000000d000020ac135cc00d2483d2e6
# stip:		0000000d00002022135cc0c33b8cef0e
# BKSPC:	0000000200000033135cbf8539a7cfa8 0000000100000033135cbf8539a7cfa8
# ENTER:	0000000d0000000a135cbfb5223d4242
# CTRL_D:	000000020000003b135cbb9d27cc4369
# CTRL_U:	000000010000003b135cbbba3a1d9828
# ALT_D:	000000020000003a135cbc0c350a5a99
# ALT_U:	000000010000003a135cbc1e062af2fe
# WIN_D:	0000000200000037135cbc2e093b0597
# WIN_U:	0000000100000037135cbc3b18c2ab33
# SCR_DN:	0000000a000000030000049b062e39d0
# SCR_UP:	0000000afff.....
# SCR_L:	0000000efff.....
# SCR_R: 	0000000e000.....
# MS_DN:	        | Speed
# MS_DN:	0000000700000027000003f22d766f23
# MS_UP:		| Speed (negative number, ffffff = -1)
# MS_UP:	00000007ffffff7400000422314c55ad
# MS_L:		00000006ffffff28000004592059cd9d
# MS_R:		000000060000000100000474156be931

sub conn_handle_data {
	my $fh = shift;
	my $conn = $conns{$fh};
	
	read $fh, my $data, 16;
	printf "TCP Received: %s\n", unpack("H*", $data);
}
