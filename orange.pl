#!/usr/bin/perl

use strict;
use warnings;

use HTTP::Request::Common qw(GET POST);
use HTTP::Cookies qw();
use LWP::UserAgent qw();
use Crypt::SSLeay qw();
use Fcntl qw(:flock :DEFAULT);

sub debug 
{ 
  my $debug = 1;
  printf STDERR "%s\n", shift if $debug; 
}

sub quit
{
  printf STDERR "%s\n", shift;
  exit 1;
}

sub api_error { quit 'API error'; }

sub extract_remaining
{
  $_ = shift;
  return int($1) + int($2) if />SMSy<:.*?>darmowe:.*?>([0-9]+)<.*>z do.*?>([0-9]+)</s;
  return int($1) if />SMSy:<.*?>darmowe:.*?>([0-9]+)</s;
  quit 'Can\'t extract number of remaining messages';
}

my $orange_home =  exists $ENV{'ORANGE_HOME'} ? $ENV{'ORANGE_HOME'} : "$ENV{'HOME'}/.orange/";
chdir $orange_home or quit "Can\'t change working directory to $orange_home";

my $ua = new LWP::UserAgent;
$ua->timeout(30);
$ua->agent('Mozilla/4.7 [en] (WinNT; I)');
$ua->env_proxy();
$ua->cookie_jar(HTTP::Cookies->new(file => './orange-cookie-jar.txt', autosave => 1, ignore_discard => 1));

sub visit 
{
  my $uri = shift;
  my $res = $ua->request(GET $uri);
  quit "Can\'t open $uri" unless $res->is_success;
  return $res;
}

open CONF, '<', './orange.conf' or quit 'Can\'t open the configuration file';
flock CONF, LOCK_SH or quit 'Can\'t lock the configuration file';
my $username = <CONF>; chomp $username;
my $password = <CONF>; chomp $password;
close CONF;

debug "Username: $username\@orange.pl";

my $action = 's';
if ($#ARGV >= 0 && $ARGV[0] =~ /^-[A-Za-z]$/)
{
  $action = shift @ARGV;
  substr $action, 0, 1, '';
}

my $number;
my $message;
my $message_len;

sub complete_net
{
  $_ = shift;
  my $net = 'invalid';
  $net = 'orange.gsm'  if /^5[0-9]{8}$/;
  $net = 'era.gsm'     if /^6[0-9][02468][0-9]{6}$/;
  $net = 'plus.gsm'    if /^6[0-9][13579][0-9]{6}$/;
  return "$_\@$net";
}

if ($action eq 'S' || $action eq 's')
{
  quit 'Invalid arguments: exactly 2 arguments required' if $#ARGV != 1;

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
  open PHONEBOOK, '<:encoding(UTF-8)', $ENV{'PHONEBOOK'} or quit 'Can\'t open the phonebook';
  flock PHONEBOOK, LOCK_SH or quit 'Can\'t lock the phonebook';
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
  $fnumber = complete_net $fnumber;
  $fname = (defined $fname) ? (' ' . encode($codeset, $fname)) : '';
  debug "Recipient:$fname <$fnumber>";

  my $pid = open3(\*MESSAGE, \*MESSAGE_ASCII, undef, '/usr/bin/konwert', 'utf8-ascii') or quit 'Can\'t invoke `konwert\'';
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
elsif ($action ne 'c' && $action ne 'i' && $action ne 'l')
{
  quit "Unknow action: $action";
}

push @{$ua->requests_redirectable}, 'POST';

my $req;
my $res;

$res = visit 'http://www.orange.pl/portal/map/map/signin';
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

$res = visit 'http://www.orange.pl/portal/map/map/message_box';
my $remaining = extract_remaining $res->content;
if ($action eq 'c')
{
  print "Number of remaining messages: $remaining\n";
  exit 0;
}
elsif ($action eq 'i')
{
  $res = visit 'http://online.orange.pl/portal/ecare';
  $_ = $res->content;
  api_error unless m{<div id="tblList3">(.*?)</div>}s;
  $_ = $1;
  y/\n\r\t/   /;
  s/ +/ /g;
  my @info = m{<td.*?>(.*?)</td>}g;
  my $pn = $info[1];
  $pn =~ s/ //g;
  my $rates = $info[6];
  my $recv = $info[16];
  $recv =~ s/^ *do ([0-9]{2})\.([0-9]{2})\.([0-9]{4}) \(([0-9]+).*$/$3-$2-$1/;
  my $recvd = $4;
  my $dial = $info[11];
  $dial =~ s/^ *do ([0-9]{2})\.([0-9]{2})\.([0-9]{4}) \(([0-9]+).*$/$3-$2-$1/;
  my $diald = $4;
  my $balance = $info[18];
  $balance =~ s/^ *([0-9]*),([0-9]*) .*$/$1.$2/;
  my $balanced = sprintf '%.2f', (0.0 + $balance) / $diald;
  print 
    "Phone number: $pn\n" .
    "Rates: $rates\n" .
    "Receiving calls till: $recv ($recvd days)\n" .
    "Dialing calls till: $dial ($diald days)\n" .
    "Balance: $balance PLN ($balanced PLN per day)\n";
}
elsif ($action eq 'l')
{
  require I18N::Langinfo; import I18N::Langinfo qw(langinfo CODESET);
  require Encode; import Encode qw(encode from_to);
  require HTML::Entities; import HTML::Entities qw(decode_entities);

  my $codeset = langinfo(CODESET()) or die;
  debug "Codeset: $codeset";

  $res = visit 'http://www.orange.pl/portal/map/map/message_box?mbox_view=sentmessageslist';
  $_ = $res->content;
  api_error unless m{<table id="list">(.*?)</table>}s;
  $_ = $1;
  y/\n\r\t/   /;
  s/ +/ /g;
  s{<thead>.*?</thead>}{};
  s{<tfoot>.*?</tfoot>}{};
  s{</?a.*?>}{}g;
  my @list = m{<td.*?>(.*?)</td>}g;

  my %phonebook;
  open PHONEBOOK, '<:encoding(UTF-8)', $ENV{'PHONEBOOK'} or quit 'Can\' open the phonebook';
  flock PHONEBOOK, LOCK_SH or quit 'Can\'t lock the phonebook';
  while (<PHONEBOOK>)
  {
    next unless /^[^#]/;
    my ($cname, $place, $cnumber, $tmp) = split /\t/;
    next unless defined($place);
    next unless $place eq '*';
    $phonebook{$cnumber} = $cname;
  }
  close PHONEBOOK;

  while ($#list >= 5)
  {
    shift @list; shift @list;
    my $cnumber = shift @list;
    my $cnumber2 = complete_net $cnumber;
    my $cname = $cnumber;
    $cname = encode($codeset, "$phonebook{$cnumber} <$cnumber2>", 'UTF-8') if exists $phonebook{$cnumber};
    my $text = shift @list;
    decode_entities($text);
    from_to($text, 'UTF-8', $codeset);
    my $date = shift @list;
    $date =~ s/ /, /;
    my $status = shift @list;
    $status = 'sent' if $status =~ /^wys/; 
    $status = 'awaiting' if $status =~ /^ocz/; 
    $status = 'delivered' if $status =~ /^dos/; 
    print "To: $cname\nDate: $date\nStatus: $status\nContents: $text\n\n";
  }
}
elsif ($action eq 'S')
{
  quit 'Message limit exceeded' if $remaining == 0;
  visit 'http://www.orange.pl/portal/map/map/message_box?mbox_view=newsms&mbox_edit=new';
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
  print "Number of remaining messages: $remaining_after\n";
}

# Written mainly on 21 Jan 2006

# vim:ts=2 sw=2 et
