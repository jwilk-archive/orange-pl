#!/usr/bin/perl

use strict;
use warnings;

use HTTP::Request::Common qw(GET POST);
use HTTP::Cookies ();
use LWP::UserAgent ();
use Crypt::SSLeay ();
use Fcntl qw(:flock :DEFAULT);
use Getopt::Long qw(:config gnu_getopt no_ignore_case);
use Pod::Usage qw(pod2usage);
use Apache::ConfigFile ();

our $VERSION = '0.20060727';
my $site = 'orange.pl';
my $cookie_domain = '.orange.pl';
my $software_name = 'orange-pl';
my $config_file = 'orange-pl.conf';
my $debug = 0;
my $person2number;
my $number2person;
my $reject_unpersons = 0;

sub quit { printf STDERR "%s\n", shift; exit 1; }

sub error
{
  my ($message, $code) = @_;
  $message .= " ($code)" if $debug;
  quit $message; 
}

sub api_error { error 'API error', "code: $_[0]"; }

sub http_error { error 'HTTP error', $_[0] }

sub debug { printf STDERR "%s\n", shift if $debug; };

sub lwp_init
{
  my $ua = new LWP::UserAgent;
  $ua->timeout(30);
  $ua->agent('Mozilla/5.0');
  $ua->env_proxy();
  $ua->cookie_jar(HTTP::Cookies->new(file => './cookie-jar.txt', autosave => 1, ignore_discard => 1));
  push @{$ua->requests_redirectable}, 'POST';
  return $ua;
}

sub expand_tilde
{
  ($_) = @_;
  s{^~([^/]*)}{length $1 > 0 ? (getpwnam($1))[7] : ( $ENV{'HOME'} || $ENV{'LOGDIR'} )}e;
  return $_;
}

sub transliterate
{
  require IPC::Open3; import IPC::Open3 qw(open3);
  local $/;
  my ($text) = @_;
  my $pid = open3(\*TEXT, \*TEXT_ASCII, undef, '/usr/bin/konwert', 'utf8-ascii') or quit q{Can't invoke `konwert'};
  binmode(TEXT, ':encoding(utf-8)');
  print TEXT $text;
  close TEXT;
  $text = <TEXT_ASCII>;
  close TEXT_ASCII;
  waitpid $pid, 0;
  return $text;
}

sub codeset
{
  require I18N::Langinfo; import I18N::Langinfo qw(langinfo CODESET);
  my $codeset = langinfo(CODESET()) or die;
  return $codeset;
}

sub resolve_number
{
  my ($number) = @_;
  if (defined $number2person)
  {
    open N2P, '-|:encoding(utf-8)', $number2person, $number or quit q(Can't invoke resolver);
    $_ = <N2P>;
    close N2P;
    my ($person) = split /\t/ if defined $_;
    return "$person <$number>" if defined $person;
  }
  return undef if $reject_unpersons;
  return "<$number>";
}

sub resolve_recipient
{
  my ($number, $recipient);
  ($recipient) = @_;
  if ($recipient =~ /[^+0-9]/ and defined $person2number)
  {
    open P2N, '-|:encoding(utf-8)', $person2number, $recipient or quit q(Can't invoke resolver);
    my @phonebook = <P2N>;
    close P2N;
    if ($#phonebook == 0)
    {
      ($_, $number) = split /\t/, $phonebook[0];
    }
    elsif ($#phonebook > 0)
    {
      print STDERR "Ambiguous recipient, please make up your mind:\n";
      print STDERR "  $_" foreach @phonebook;
      exit 1;
    }
    else
    {
      $number = '';
    }
  }
  else
  {
    $number = $recipient;
  }
  quit 'No such recipient' unless $number =~ /^(\+48)?([0-9]{9})$|^([0-9]{11})$/;
  $number = $3 if defined $3;
  $number = $2 if defined $2;
  $recipient = resolve_number($number);
  quit 'No such recipient' unless defined $recipient;
  return ($number, $recipient);
}

sub lwp_visit
{
  my $ua = shift;
  my $uri = shift;
  my $res = $ua->request(GET $uri);
  http_error $uri unless $res->is_success;
  return $res;
}

my $list_limit;
my $list_expand;
my $action = 's';
my $force = 0;
GetOptions(
  'send|s|S' =>       sub { $action = 's'; },
  'count|c' =>        sub { $action = 'c'; },
  'logout' =>         sub { $action = '0'; },
  'info|i' =>         sub { $action = 'i'; },
  'list-sent|l:i'  => sub { $action = 'l'; ($_, $list_limit) = @_; },
  'list-inbox|m:i' => sub { $action = 'm'; ($_, $list_limit) = @_; },
  'expand' =>         \$list_expand,
  'force' =>          \$force,
  'version' =>        sub { quit "$software_name, version $VERSION"; },
  'debug' =>          \$debug,
  'help|h|?' =>       sub { pod2usage(1); }
) or pod2usage(1);
if (defined $list_limit)
{
  pod2usage(1) unless $list_limit =~ /^[0-9]{1,4}$/;
  $list_limit = 9999 if $list_limit == 0;
}

my $env = $software_name;
$env =~ s/\W//g;
$env =~ y/a-z/A-Z/;
$env .= '_HOME';
my $home = exists $ENV{$env} ? $ENV{$env} : "$ENV{'HOME'}/.$software_name/";
chdir $home or quit "Can't change working directory to $home";

my $ua = lwp_init();

my $login = '';
my $password;

my %conf_vars = 
(
  'login' => sub 
    { $login = shift; },
  'password' => sub 
    { $password = shift; },
  'password64' => sub
    { 
      use MIME::Base64 ();
      $password = MIME::Base64::decode(shift);
    },
  'number2person' => sub 
    { $number2person = expand_tilde(shift); },
  'person2number' => sub 
    { $person2number = expand_tilde(shift); },
  'reject_unpersons' => sub 
    { $reject_unpersons = parse_yes_no(shift); },
  'debug' => sub 
    { $debug = shift; },
);

my $ac = Apache::ConfigFile->read(file => $config_file, ignore_case => 1, fix_booleans => 1, raise_error => 1);
foreach my $context (($ac, $ac->cmd_context(site => $site)))
{
  foreach my $var (keys %conf_vars)
  {
    my $val = $context->cmd_config($var);
    $conf_vars{$var}($val) if defined $val;
  }
}

$reject_unpersons = 0 if $force;
quit 'No login name provided' unless length $login > 0;
quit 'No password provided' unless defined $password;


debug "Login: $login\@$site";

my $number;
my $body;
my $body_len;


if ($action eq 's')
{
  pod2usage(1) if $#ARGV != 1;

  require Encode; import Encode qw(encode decode);
  require Text::Wrap; import Text::Wrap qw(wrap);
  my $codeset = codeset();
  debug "Codeset: $codeset";
  binmode STDERR, ":encoding($codeset)";
  binmode STDOUT, ":encoding($codeset)";
  
  (my $recipient, $body) = @ARGV;
  $recipient = decode($codeset, $recipient);
  $body = decode($codeset, $body);
  ($number, $recipient) = resolve_recipient $recipient;
  debug "Recipient: $recipient";
  $body = transliterate($body); 
  debug "Message: \n" . wrap("  ", "  ", $body);
  $body_len = length $body;
  debug "Message length: $body_len";
  quit "Message too long ($body_len > 640)" if $body_len > 640;
}
elsif ($action eq '0')
{
  $ua->cookie_jar->clear($cookie_domain);
  debug 'Cookies has been purged';
  exit;
}

my $res;

my $signin_uri = 'http://www.orange.pl/portal/map/map/signin';
$res = lwp_visit $ua, $signin_uri;
unless ($res->content =~ /zalogowany jako/i)
{
  debug 'Logging in...';
  my $uri = 'https://www.orange.pl/portal/map/map/signin?_DARGS=/gear/static/signIn.jsp';
  my $a = '/amg/ptk/map/core/formhandlers/AdvancedProfileFormHandler';
  my $req = POST $uri, 
    [
      "$a.login" => ' ', "$a.login.x" => 0, "$a.login.y" => 0,
      "$a.loginErrorURL" => 'http://www.orange.pl/portal/map/map/signin',
      "$a.loginSuccessURL" => 'http://www.orange.pl/portal/map/map/pim',
      "$a.value.login" => $login, "$a.value.password" => $password,
      "_D:$a.login" => ' ', "_D:$a.loginErrorURL" => ' ', "_D:$a.loginSuccessURL" => ' ',
      "_D:$a.value.login" => ' ', "_D:$a.value.password" => ' ',
      '_DARGS' => '/gear/static/signIn.jsp',
      '_dyncharset' => 'UTF-8'
    ];
  $req->referer($signin_uri);
  $res = $ua->request($req);
  http_error $signin_uri unless $res->is_success();
  quit 'Login error: incorrect password, I guess...' unless $res->content =~ /zalogowany jako/i;
}
debug 'Logged in!';

sub extract_remaining
{
  ($_) = @_;
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
}
elsif ($action eq 'i')
{
  my $uri = 'http://online.orange.pl/portal/ecare';
  $res = lwp_visit $ua, $uri;
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
  require Encode; import Encode qw(decode);
  require HTML::Entities; import HTML::Entities qw(decode_entities);

  my $codeset = codeset();
  debug "Codeset: $codeset";
  binmode STDOUT, ":encoding($codeset)";

  my $pg;
  $pg = 'sentmessageslist' if $action eq 'l';
  $pg = 'messageslist' if $action eq 'm';
  $res = lwp_visit $ua, "http://www.orange.pl/portal/map/map/message_box?mbox_view=$pg";
  $_ = $res->content;
  s/\s+/ /g;
  api_error 'l1' unless m{<table id="list">(.*?)</table>};
  $_ = $1;
  s{<thead>.*?</thead>}{};
  s{<tfoot>.*?</tfoot>}{};
  my @urls = m{(?<=<a href=")/portal/map/map/message_box\?[^"]*(?=">)}g;
  s{</?a.*?>}{}g;
  my @list = m{<td.*?>(.*?)</td>}g;
 
  while ($#list >= 4 && $list_limit > 0)
  {
    shift @list; shift @list;
    my $url = shift @urls;
    api_error 'l3' if $url ne shift @urls;
    my $cname = resolve_number shift @list;
    my $text = shift @list;
    decode_entities($text);
    $text = decode('UTF-8', $text);
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
    if ($list_expand)
    {
      require Text::Wrap; import Text::Wrap qw(wrap);
      $res = lwp_visit $ua, "http://www.orange.pl$url";
      $_ = $res->content;
      api_error 'l4' unless m{<div class="message-body"><pre>(.*)</pre></div>}s;
      $text = decode_entities($1);
      $text = decode('UTF-8', $text);
      $text = "\n" . wrap("  ", "  ", $text);
    }
    print "Contents: $text\n\n";
    $list_limit--;
  }
}
elsif ($action eq 's')
{
  quit 'Message limit exceeded' if $remaining == 0;
  my $newmsg_uri = 'http://www.orange.pl/portal/map/map/message_box?mbox_view=newsms&mbox_edit=new';
  $res = lwp_visit $ua, $newmsg_uri;
  debug 'Ready to send...';
  my $uri = 'http://www.orange.pl/portal/map/map/message_box??_DARGS=/gear/mapmessagebox/smsform.jsp';
  my $a = '/amg/ptk/map/messagebox/formhandlers/MessageFormHandler';
  my $req = POST $uri, 
    [
      '_dyncharset' => 'UTF-8',
      "$a.body" => $body,
      "$a.create.x" => 0, "$a.create.y" => 0,
      "$a.errorURL" => '/portal/map/map/message_box?mbox_view=newsms',
      "$a.successURL" => '/portal/map/map/message_box?mbox_view=messageslist',
      "$a.to" => $number, "$a.type" => 'sms',
      "_D:$a.body" => ' ', "_D:$a.create" => ' ', "_D:$a.errorURL"  => ' ', 
      "_D:$a.successURL" => ' ', "_D:$a.to" => ' ', "_D:$a.type" => ' ',
      '_DARGS' => '/gear/mapmessagebox/smsform.jsp',
      'counter' => 640 - $body_len
    ];
  $req->referer($newmsg_uri);
  debug 'Sending...';
  $res = $ua->request($req);
  http_error $uri unless $res->is_success;
  my $remaining_after = extract_remaining $res->content;
  quit 'Error while sending the message, I guess...' unless $remaining_after < $remaining;
  debug 'Looks OK';
  debug "Number of remaining messages: $remaining_after";
}

__END__

=head1 NAME

orange.pl -- send SMs via orange.pl gateway

=head1 SYNOPSIS

=over 4

=item orange.pl [-s] [--force] I<< <phonebook-entry> >> I<< <text> >>

=item orange.pl -c

=item orange.pl -l [I<N>] [--expand]

=item orange.pl -m [I<N>] [--expand]

=item orange.pl -i

=back

=head1 ENVIRONMENT

ORANGEPL_HOME (default: F<$HOME/.orange-pl/>)

=head1 FILES

=over 4

=item F<$ORANGEPL_HOME/orange-pl.conf>

=item F<$ORANGEPL_HOME/cookie-jar.txt>

=back

=head1 AUTHOR

Written by Jakub Wilk E<lt>ubanus@users.sf.netE<gt>, mainly on 21 Jan 2006.

=head1 COPYRIGHT

You may redistribute copies of B<orange-pl> under the terms of the GNU General Public License, version 2.

=cut

# vim:ts=2 sw=2 et
