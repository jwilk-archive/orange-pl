#!/usr/bin/perl

use strict;
use warnings;

use HTTP::Request::Common qw(GET POST);
use HTTP::Cookies qw();
use LWP::UserAgent qw();
use Crypt::SSLeay qw();
use Fcntl qw(:flock :DEFAULT);
use Getopt::Long qw(:config gnu_getopt no_ignore_case);
use Pod::Usage qw(pod2usage);

my $debug = 0;

sub quit { printf STDERR "%s\n", shift; exit 1; }

sub api_error 
{ 
  my $message = 'API error';
  if ($debug)
  {
    my $code = shift;
    $message .= " (code: $code)";
  }
  quit $message; 
}

sub debug { printf STDERR "%s\n", shift if $debug; };

sub gsm_complete_net
{
  $_ = shift;
  my $net = 'invalid';
  $net = 'orange.gsm'  if /^5[0-9]{8}$/;
  $net = 'era.gsm'     if /^6[0-9][02468][0-9]{6}$/;
  $net = 'plus.gsm'    if /^6[0-9][13579][0-9]{6}$/;
  return "$_\@$net";
}

sub lwp_init
{
  my $ua = new LWP::UserAgent;
  $ua->timeout(30);
  $ua->agent('Mozilla/4.7 [en] (WinNT; I)');
  $ua->env_proxy();
  $ua->cookie_jar(HTTP::Cookies->new(file => './orange-pl-cookie-jar.txt', autosave => 1, ignore_discard => 1));
  push @{$ua->requests_redirectable}, 'POST';
  return $ua;
}

sub lwp_visit
{
  my $ua = shift;
  my $uri = shift;
  my $res = $ua->request(GET $uri);
  quit "Can't open $uri" unless $res->is_success;
  return $res;
}

our $VERSION = '0.20060714';
my $action = 's';
GetOptions(
  'send|s' =>       sub { $action = 's'; },
  'force-send|S' => sub { $action = 'S'; },
  'count|c' =>      sub { $action = 'c'; },
  'info|i' =>       sub { $action = 'i'; },
  'list-sent|l' =>  sub { $action = 'l'; },
  'list-inbox|m' => sub { $action = 'm'; },
  'version' =>      sub { quit "orange.pl $VERSION"; },
  'debug' =>        \$debug,
  'help|h|?' =>     sub { pod2usage(1); }
) or pod2usage(1);

my $orange_home = exists $ENV{'ORANGEPL_HOME'} ? $ENV{'ORANGEPL_HOME'} : "$ENV{'HOME'}/.orange-pl/";
chdir $orange_home or quit "Can't change working directory to $orange_home";


my $ua = lwp_init;

open CONF, '<', './orange-pl.conf' or quit q(Can't open the configuration file);
flock CONF, LOCK_SH or quit q(Can't lock the configuration file);
my $username = <CONF>; chomp $username;
my $password = <CONF>; chomp $password;
close CONF;

debug "Username: $username\@orange.pl";

my $number;
my $message;
my $message_len;

if ($action eq 'S' || $action eq 's')
{
  pod2usage(1) if $#ARGV != 1;

  require I18N::Langinfo; import I18N::Langinfo qw(langinfo CODESET);
  require Encode; import Encode qw(decode encode);
  require IPC::Open3; import IPC::Open3 qw(open3);
  require Text::Wrap; import Text::Wrap qw(wrap);
  my $codeset = langinfo(CODESET()) or die;
  debug "Codeset: $codeset";

  $number = decode($codeset, $ARGV[0]);
  $message = decode($codeset, $ARGV[1]);
   
  $number =~ s/^\+48//;
  $number =~ s/^00//;
  my $grep = $number !~ /^[0-9]{9,11}$/;
  my ($fnumber, $fname);
  open PHONEBOOK, '<:encoding(UTF-8)', $ENV{'PHONEBOOK'} or quit q(Can't open the phonebook);
  flock PHONEBOOK, LOCK_SH or quit q(Can't lock the phonebook);
  my $found = 0;
  while (<PHONEBOOK>)
  {
    next unless /^[^#]/;
    my ($cname, $place, $cnumber, $tmp) = split /\t/;
    next unless defined($place);
    next unless $place eq '*';
    if (($grep && index($cname, $number) >= 0) || (!$grep && $cnumber == $number))
    {
      quit 'Invalid argument: ambiguous recipient' if $found++;
      ($fnumber, $fname) = ($cnumber, $cname);
    }
  }
  close PHONEBOOK;
  $found = !$grep if $action eq 'S';
  quit 'Invalid argument: no such recipient' unless $found;
  $fnumber = $number unless defined $fnumber;
  chomp $fnumber;
  $number = $fnumber;
  $fnumber = gsm_complete_net $fnumber;
  $fname = (defined $fname) ? (' ' . encode($codeset, $fname)) : '';
  debug "Recipient:$fname <$fnumber>";

  my $pid = open3(\*MESSAGE, \*MESSAGE_ASCII, undef, '/usr/bin/konwert', 'utf8-ascii') or quit q{Can't invoke `konwert'};
  $message = encode('UTF-8', $message);
  print MESSAGE $message;
  close MESSAGE;
  {
    local $/;
    $message = <MESSAGE_ASCII>;
  }
  close MESSAGE_ASCII;
  waitpid $pid, 0;
  debug "Message: \n" . wrap("  ", "  ", $message);
  $message_len = length $message;
  debug "Message length: $message_len";
  quit "Message too long ($message_len > 640)" if $message_len > 640;
  $action = 'S';
}
elsif ($action !~ '^[cilm]$')
{
  quit "Unknow action: $action";
}

my $req;
my $res;

$res = lwp_visit $ua, 'http://www.orange.pl/portal/map/map/signin';
unless ($res->content =~ /zalogowany jako/i)
{
  debug 'Logging in...';
  my $uri = 'https://www.orange.pl/portal/map/map/signin?_DARGS=/gear/static/signIn.jsp';
  my $a = '/amg/ptk/map/core/formhandlers/AdvancedProfileFormHandler';
  $req = POST $uri, 
    [
      "$a.login" => ' ', "$a.login.x" => 0, "$a.login.y" => 0,
      "$a.loginErrorURL" => 'http://www.orange.pl/portal/map/map/signin',
      "$a.loginSuccessURL" => 'http://www.orange.pl/portal/map/map/pim',
      "$a.value.login" => $username, "$a.value.password" => $password,
      "_D:$a.login" => ' ', "_D:$a.loginErrorURL" => ' ', "_D:$a.loginSuccessURL" => ' ',
      "_D:$a.value.login" => ' ', "_D:$a.value.password" => ' ',
      '_DARGS' => '/gear/static/signIn.jsp',
      '_dyncharset' => 'UTF-8'
    ];
  $req->referer('http://www.orange.pl/portal/map/map/signin');
  $res = $ua->request($req);
  quit "Login error ($uri)" unless $res->is_success;
  quit 'Login error: incorrect password, I guess...' unless $res->content =~ /zalogowany jako/i;
}
debug 'Logged in!';

sub extract_remaining
{
  $_ = shift;
  if (m{<div id="syndication">(.*?)</div>}s)
  {
    $_ = $1;
    my $sum = 0;
    $sum += $1 while m{<span class="value">([0-9]+)</span>}sg;
    return $sum;
  }
  api_error 'x1';
}

$res = lwp_visit $ua, 'http://www.orange.pl/portal/map/map/message_box';
my $remaining = extract_remaining $res->content;
if ($action eq 'c')
{
  print "Number of remaining messages: $remaining\n";
  exit 0;
}
elsif ($action eq 'i')
{
  $res = lwp_visit $ua, 'http://online.orange.pl/portal/ecare';
  $_ = $res->content;
  s/\s+/ /g;
  api_error 'i1' unless m{<div id="tbl-list3">.*?<table>(.*?)</table>};
  $_ = $1;
  my @info = m{<td.*?>(.*?)</td>}sg;
  $_ = join "\n", @info;
  api_error 'i2.' . $#info unless $#info >= 13;
  my $pn = $info[1];
  $pn =~ s/ //g;
  api_error 'i6' unless $pn =~ '^[0-9]+$';
  my $rates = $info[4];
  $rates =~ s/^ +//g;
  $rates =~ s/ +$//g;
  my $recv = $info[10];
  api_error 'i3' unless $recv =~ /^ *do ([0-9]{2})\.([0-9]{2})\.([0-9]{4}) \(([0-9]+).*/;
  $recv =~ s//$3-$2-$1/;
  my $recvd = $4;
  my $dial = $info[7];
  api_error 'i4' unless $dial =~ /^ *do ([0-9]{2})\.([0-9]{2})\.([0-9]{4}) \(([0-9]+).*/;
  $dial =~ s//$3-$2-$1/;
  my $diald = $4;
  my $balance = $info[13];
  api_error 'i5' unless $balance =~ /^ *([0-9]+),([0-9]+) .*$/;
  $balance =~ s//$1.$2/;
  my $balanced = sprintf '%.2f', (0.0 + $balance) / $diald;
  print 
    "Phone number: $pn\n",
    "Rates: $rates\n",
    "Receiving calls till: $recv ($recvd days)\n",
    "Dialing calls till: $dial ($diald days)\n",
    "Balance: $balance PLN ($balanced PLN per day)\n";
}
elsif ($action eq 'l' || $action eq 'm')
{
  require I18N::Langinfo; import I18N::Langinfo qw(langinfo CODESET);
  require Encode; import Encode qw(encode from_to);
  require HTML::Entities; import HTML::Entities qw(decode_entities);

  my $codeset = langinfo(CODESET()) or die;
  debug "Codeset: $codeset";

  my $pg;
  $pg = 'sentmessageslist' if $action eq 'l';
  $pg = 'messageslist' if $action eq 'm';
  $res = lwp_visit $ua, 'http://www.orange.pl/portal/map/map/message_box?mbox_view=' . $pg;
  $_ = $res->content;
  s/\s+/ /g;
  api_error 'l1' unless m{<table id="list">(.*?)</table>};
  $_ = $1;
  s{<thead>.*?</thead>}{};
  s{<tfoot>.*?</tfoot>}{};
  s{</?a.*?>}{}g;
  my @list = m{<td.*?>(.*?)</td>}g;

  my %phonebook;
  if (open PHONEBOOK, '<:encoding(UTF-8)', $ENV{'PHONEBOOK'})
  {
    flock PHONEBOOK, LOCK_SH or quit q{Can't lock the phonebook};
    while (<PHONEBOOK>)
    {
      next unless /^[^#]/;
      my ($cname, $place, $cnumber, $tmp) = split /\t/;
      next unless defined($place);
      next unless $place eq '*' or $place eq '<mbox>';
      $phonebook{$cnumber} = $cname;
    }
    close PHONEBOOK;
  }
  else 
  {
    debug q{Can't open the phonebook};
  }
  
  while ($#list >= 4)
  {
    shift @list; shift @list;
    my $cnumber = shift @list;
    my $cnumber2 = gsm_complete_net $cnumber;
    my $cname = $cnumber;
    $cname = encode($codeset, "$phonebook{$cnumber} <$cnumber2>", 'UTF-8') if exists $phonebook{$cnumber};
    my $text = shift @list;
    decode_entities($text);
    from_to($text, 'UTF-8', $codeset);
    my $date = shift @list;
    $date =~ s/ /, /;
    my $hdr = 'To';
    $hdr = 'From' if $action eq 'm';
    print "$hdr: $cname\nDate: $date\n";
    if ($action eq 'l')
    {
      my $status = shift @list;
      $status = 'sent' if $status =~ /^wys/; 
      $status = 'awaiting' if $status =~ /^ocz/; 
      $status = 'delivered' if $status =~ /^dos/;
      print "Status: $status\n";
    }
    print "Contents: $text\n\n";
  }
}
elsif ($action eq 'S')
{
  quit 'Message limit exceeded' if $remaining == 0;
  lwp_visit $ua, 'http://www.orange.pl/portal/map/map/message_box?mbox_view=newsms&mbox_edit=new';
  debug 'Ready to send...';
  my $uri = 'http://www.orange.pl/portal/map/map/message_box??_DARGS=/gear/mapmessagebox/smsform.jsp';
  my $a = '/amg/ptk/map/messagebox/formhandlers/MessageFormHandler';
  $req = POST $uri, 
    [
      '_dyncharset' => 'UTF-8',
      "$a.body" => $message,
      "$a.create.x" => 0, "$a.create.y" => 0,
      "$a.errorURL" => '/portal/map/map/message_box?mbox_view=newsms',
      "$a.successURL" => '/portal/map/map/message_box?mbox_view=messageslist',
      "$a.to" => $number, "$a.type" => 'sms',
      "_D:$a.body" => ' ', "_D:$a.create" => ' ', "_D:$a.errorURL"  => ' ', 
      "_D:$a.successURL" => ' ', "_D:$a.to" => ' ', "_D:$a.type" => ' ',
      '_DARGS' => '/gear/mapmessagebox/smsform.jsp',
      'counter' => 640 - $message_len
    ];
  $req->referer('http://www.orange.pl/portal/map/map/message_box?mbox_view=newsms&mbox_edit=new');
  debug 'Sending...';
  $res = $ua->request($req);
  quit "Error while sending the message ($uri)" unless $res->is_success;
  my $remaining_after = extract_remaining $res->content;
  quit 'Error while sending the message, I guess...' unless $remaining_after < $remaining;
  debug 'Looks OK';
  debug "Number of remaining messages: $remaining_after\n";
}

__END__

=head1 NAME

orange.pl -- send SMs via orange.pl gateway

=head1 SYNOPSIS

=over 4

=item orange [-s] I<< <phonebook-entry> >> I<< <text> >>

=item orange -S I<< <phone-number> >> I<< <text> >>

=item orange -c

=item orange -l

=item orange -m

=item orange -i

=back

=head1 ENVIRONMENT

ORANGEPL_HOME (default: F<$HOME/.orange-pl/>)

=head1 FILES

=over 4

=item F<$ORANGEPL_HOME/orange-pl.conf>

The configuration file is in the following format:

I<[login-name]>  I<[password]>

where fields are newline-separated.

=item F<$ORANGEPL_HOME/orange-pl-cookie-jar.txt>

=item F<$ORANGEPL_HOME/phonebook>

The phonebook is consisted of lines in the following format:

I<[personal-name]>  I<[place]>  I<[phone-number]>

where fields are tab-separated; I<[place]> must be set to C<*> for a cellular phone number, or to C<< <mbox> >> for a mbox phone number.

=back

=head1 AUTHOR

Written by Jakub Wilk E<lt>ubanus@users.sf.netE<gt>, mainly on 21 Jan 2006.

=head1 COPYRIGHT

You may redistribute copies of B<orange-pl> under the terms of the GNU General Public License, version 2.

=cut

# vim:ts=2 sw=2 et
