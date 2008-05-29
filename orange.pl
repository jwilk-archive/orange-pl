#!/usr/bin/perl

use strict;
use warnings;

package OrangePl;

use base qw(kawute);

use POSIX qw(mktime ceil);

our $VERSION = '0.8.11';

sub version($) { $OrangePl::VERSION; }
sub site($) { 'orange.pl'; }
sub software_name($) { 'orange-pl'; }
sub config_file($) { 'orange-pl.conf'; }
sub cookie_domain($) { '.orange.pl'; }

sub lwp_init($)
{
  require Crypt::SSLeay;
  $ENV{HTTPS_CA_DIR} = '/etc/ssl/certs/' if not defined $ENV{HTTPS_CA_DIR};
  my ($this) = @_;
  my $ua = kawute::lwp_init($this);
  push @{$ua->requests_redirectable}, 'POST';
  return $ua;
}

sub fix_number($$)
{
  my ($this, $number) = @_;
  $this->quit('No such recipient') unless $number =~ /^(?:\+?48)?(\d{9})$|^(\d{11})$/;
  $number = $2 if defined $2;
  $number = $1 if defined $1;
  return $number;
}

sub number_of_days($)
{
  ($_) = @_;
  $_ = int ($_);
  return "$_ day" . ($_ == 1 ? '' : 's');
}

my $list_limit;
my $list_expand;
my $folder = 'INBOX';
my $login = '';
my $password;
my $ua;
my $proto = 'https';

sub main($)
{
  my ($this) = @_;
  my $action_void   = sub { $this->action_void(); };
  my $action_send   = sub { $this->action_send(); };
  my $action_count  = sub { $this->action_count(); };
  my $action_inbox  = sub { $this->action_list(0); };
  my $action_sent   = sub { $this->action_list(1); };
  my $action_info   = sub { $this->action_info(); };
  my $action_logout = sub { $this->action_logout(); };
  my $action = $action_send;
  $this->get_options(
    'send|s|S' =>       sub { $action = $action_send; },
    'count|c' =>        sub { $action = $action_count; },
    'list-inbox|m:i' => sub { $action = $action_inbox; ($_, $list_limit) = @_; },
    'list-sent|l:i'  => sub { $action = $action_sent; ($_, $list_limit) = @_; },
    'expand' =>         \$list_expand,
    'folder=s' =>       \$folder,
    'info|i' =>         sub { $action = $action_info; },
    'logout' =>         sub { $action = $action_logout; },
    'void' =>           sub { $action = $action_void; },
  );
  if (defined $list_limit)
  {
    $this->pod2usage(1) unless $list_limit =~ /^\d{1,4}$/;
    $list_limit = 9999 if $list_limit == 0;
  }
  $this->pod2usage(1) unless $folder =~ /^\w+$/;
  $this->go_home();
  $this->read_config
  (
    'login' => sub 
      { $login = shift; },
    'password' => sub 
      { $password = shift; },
    'password64' => sub
      { 
        require MIME::Base64;
        $password = MIME::Base64::decode(shift);
      },
    'usessl' => sub 
      { $proto = shift() ? 'https' : 'http'; },
  );
  $this->reject_unpersons(0) if $this->force();
  $this->quit('No login name provided') unless length $login > 0;
  $this->quit('No password provided') unless defined $password;
  $this->debug_print("Login: $login\@" . $this->site());
  &{$action}();
}

sub END()
# FIXME: This does not inherit well... :/
{
  my $this = __PACKAGE__;
  return unless defined $ua;
  $ua->cookie_jar->scan(
    sub
    {
      my ($version, $key, $val, $path, $domain, $port, $path_spec, $secure, $expires, $discard) = @_;
      return unless $domain eq $this->cookie_domain();
      $ua->cookie_jar->set_cookie($version, $key, $val, $path, $domain, $port, $path_spec, $secure, 86400, $discard) unless defined $expires;
    }
  );
}

sub extract_remaining($$)
{
  (my $this, $_) = @_;
  if (m{<div id="syndication">(.*?)</div>}s)
  {
    $_ = $1;
    my $sum = 0;
    my $n = 0;
    $sum += $1, $n++ while m{<span class="value">(\d+)</span>}sg;
    return $sum if $n > 0;
  }
  $this->api_error('x1');
}

sub do_login($)
{
  my ($this) = @_;
  $ua = $this->lwp_init();
  my $res;
  my $signin_uri = "$proto://www.orange.pl/portal/map/map/signin";
  $res = $this->lwp_visit($ua, $signin_uri);
  unless ($res->content =~ /zalogowany jako/i)
  {
    $this->debug_print('Logging in...');
    my $uri = 'https://www.orange.pl/portal/map/map/signin?_DARGS=/gear/static/signInLoginBox.jsp';
    my $a = '/amg/ptk/map/core/formhandlers/AdvancedProfileFormHandler';
    my $req = $this->lwp_post($uri, 
      [
        "$a.login" => ' ', "$a.login.x" => 0, "$a.login.y" => 0,
        "$a.loginErrorURL" => "$proto://www.orange.pl/portal/map/map/signin",
        "$a.loginSuccessURL" => "$proto://www.orange.pl/portal/map/map/pim",
        "$a.value.login" => $login, "$a.value.password" => $password,
        "_D:$a.login" => ' ', "_D:$a.loginErrorURL" => ' ', "_D:$a.loginSuccessURL" => ' ',
        "_D:$a.value.login" => ' ', "_D:$a.value.password" => ' ',
        '_DARGS' => '/gear/static/signIn.jsp',
        '_dyncharset' => 'UTF-8'
      ]);
    $req->referer($signin_uri);
    $res = $ua->request($req);
    $this->http_error($signin_uri) unless $res->is_success();
    $this->quit('Login error: incorrect password, I guess...') unless $res->content =~ /zalogowany jako/i;
  }
  $this->debug_print('Logged in!');
  $res = $this->lwp_visit($ua, "$proto://www.orange.pl/portal/map/map/message_box");
  return $this->extract_remaining($res->content);
}

sub action_count($)
{
  my ($this) = @_;
  my $remaining = $this->do_login();
  print "Number of remaining messages: $remaining\n";
}

sub action_info($)
{
  my ($this) = @_;
  $this->do_login();
  my $res = $this->lwp_visit($ua, "$proto://online.orange.pl/portal/ecare");
  $_ = $res->content;
  s/\s+/ /g;
  $this->api_error('i1') unless m{<div id="tbl-list3">.*?<table>(.*?)</table>};
  $_ = $1;
  my ($pn, $rates, $recv, $dial, $balance) = m{<td class="value(?:-orange)??"(?: colspan="\d+")??>(.*?)</td>}sg;
  defined $pn or $this->api_error('if0d');
  $pn =~ s/ //g;
  $pn =~ '^\d+$' or $this->api_error('if0');
  defined $rates or $this->api_error('if1d');
  $rates =~ s/^ +//g;
  $rates =~ s/ +$//g;
  defined $recv or $this->api_error('if3d');
  if ($recv =~ /^ *-/)
  {
    $recv = ': disabled';
  }
  else
  {
    $recv =~ /^ *do (\d{2})\.(\d{2})\.(\d{4}) \((\d+)/ or $this->api_error('if3');
    $recv = " till: $3-$2-$1 (" . number_of_days($4) . ' left)';
  }
  defined $dial or $this->api_error('if2d');
  my $diald = 0.0;
  if ($dial =~ /^ *-/)
  {
    $dial = ': disabled'
  }
  else
  {
    $dial =~ /^ *do (\d{2})\.(\d{2})\.(\d{4}) \((\d+)/ or $this->api_error('if2');
    $diald = $4;
    $dial = " till: $3-$2-$1 (" . number_of_days($diald) . ' left)';
  }
  defined $balance or $this->api_error('if4d');
  $balance =~ /^ *(\d+),(\d+) .*$/ or $this->api_error('if4');
  $balance =~ s//$1.$2/;
  my $balance_per_day = '';
  $balance_per_day = sprintf ' (%.2f PLN per day)', (0.0 + $balance) / $diald if $diald > 0;
  print 
    "Phone number: $pn\n",
    "Rates: $rates\n",
    "Receiving calls$recv\n",
    "Dialing calls$dial\n",
    "Balance: $balance PLN$balance_per_day\n";
  $res = $this->lwp_visit($ua, "$proto://online.orange.pl/portal/ecare/packages");
  my $package_re_tmp = '<div class="package-title"><span>%s</span></div>\s*<div.*?>.*?<strong>(.*?)</strong>\s*</div>\s*<div class="package-date">(.*?)</div>';
  my $package_re = sprintf($package_re_tmp, 'Orange SMS/MMS');
  if ($res->content =~ /$package_re/s)
  {
    my $n = $1;
    my $expiry = $2;
    my $ndays;
    $n =~ m{^\s*(\d+)\s+SMS\s*/\s*(\d+)\s+MMS\s*$} or $this->api_error('ip1');
    my $m = $2;
    $n = $1;
    if ($expiry =~ /^\s*$/)
    {
      $expiry = 'expired';
    }
    else
    {
      $expiry =~ /<strong>\s*(\d{2})\.(\d{2})\.(\d{4}) \((\d+)/ or $this->api_error('ip2');
      $ndays = ceil((mktime(0, 0, 0, $1, $2 - 1, $3 - 1900) - time) / 86400.0);
      $expiry = "$3-$2-$1 (" . number_of_days($ndays) . ' left)';
    }
    print "Package: $n SMs or $m MMs\n";
    print "Package valid till: $expiry\n";
  }
  else
  {
    print "No SMS packages available.\n";
  }
  $package_re = sprintf($package_re_tmp, "Dodatkowe \xc5\x9brodki");
  if ($res->content =~ /$package_re/s)
  {
    my $balance = $1;
    my $expiry = $2;
    $balance =~ s/^\s*(\d+),(\d+).*/$1.$2/s or $this->api_error('iar1');
    $expiry =~ /<strong>\s*(\d{2})\.(\d{2})\.(\d{4}) \((\d+)/ or $this->api_error('iar2');
    my $ndays = ceil((mktime(0, 0, 0, $1, $2 - 1, $3 - 1900) - time) / 86400.0);
    my $balance_per_day = '';
    $balance_per_day = sprintf ' (%.2f PLN per day)', (0.0 + $balance) / $ndays if $ndays > 0;
    print "Additional resources: $balance PLN$balance_per_day\n";
    $expiry = "$3-$2-$1 (" . number_of_days($ndays) . ' left)';
    print "Additional resources valid till: $expiry\n";
  }
  $package_re = sprintf($package_re_tmp, "\xc5\x9arodki z promocji Darmowy Weekend");
  if ($res->content =~/$package_re/s)
  {
    my $balance = $1;
    my $expiry = $2;
    $balance =~ s/^(\d+) min[.] (\d+) s/$1 * 60 + $2/e or $this->api_error('ifw1');
    $expiry =~ /<strong>\s*(\d{2})\.(\d{2})\.(\d{4}) \((\d+)/ or $this->api_error('ifw2');
    $expiry = "$3-$2-$1";
    printf "'Free Weekend' free time: %.1f h\n", (0.0 + $balance) / 60 / 60;
    print "'Free Weekend' valid till: $expiry\n";
  }
}

sub action_list($$)
{
  require Encode; import Encode qw(decode);
  require HTML::Entities; import HTML::Entities qw(decode_entities);
  
  my ($this, $sentbox) = @_;

  $this->do_login();

  my $codeset = $this->codeset();
  $this->debug("Codeset: $codeset");
  binmode STDOUT, ":encoding($codeset)";

  my $pg;
  $pg = 'sentmessageslist' if $sentbox;
  $pg = "messageslist&mbox_folder=$folder" unless $sentbox;
  my $res = $this->lwp_visit($ua, "$proto://www.orange.pl/portal/map/map/message_box?mbox_view=$pg");
  $_ = $res->content;
  s/\s+/ /g;
  $this->api_error('l1') unless m{<table id="list">(.*?)</table>};
  $_ = $1;
  s{<thead>.*?</thead>}{};
  s{<tfoot>.*?</tfoot>}{};
  my @urls = m{(?<=<a href=")/portal/map/map/message_box\?[^"]*(?=">)}g;
  s{</?a.*?>}{}g;
  my @list = m{<td.*?>(.*?)</td>}g;
 
  while ($#list >= 4 && $list_limit > 0)
  {
    my $type = shift @list;
    $type =~ m{([^/]*)\.gif"} or $this->api_error('l5');
    print "Type: $1\n";
    shift @list;
    my $url = shift @urls;
    $this->api_error('l3') if $url ne shift @urls;
    my $cname = shift @list;
    $cname = $this->resolve_number($cname) if $cname =~ /^\+?\d+$/;
    my $text = shift @list;
    decode_entities($text);
    $text = decode('UTF-8', $text);
    my $date = shift @list;
    $date =~ s/ /, /;
    my $hdr = 'To';
    $hdr = 'From' unless $sentbox;
    print "$hdr: $cname\nDate: $date\n";
    if ($sentbox)
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
      $res = $this->lwp_visit($ua, "$proto://www.orange.pl$url");
      $_ = $res->content;
      if (m{<div class="message-body"><pre>(.*)</pre></div>}s)
      {
        $text = decode_entities($1);
        $text = decode('UTF-8', $text);
        $text = "\n" . wrap('  ', '  ', $text);
      }
    }
    print "Contents: $text\n\n";
    $list_limit--;
  }
}

sub action_send($)
{
  my ($this) = @_;
  
  $this->pod2usage(1) if $#ARGV != 1;

  require Encode;
  require Text::Wrap;
  my $codeset = $this->codeset();
  $this->debug_print("Codeset: $codeset");
  binmode STDERR, ":encoding($codeset)";
  binmode STDOUT, ":encoding($codeset)";
  
  my ($number, $body, $body_len, $recipient);
  ($recipient, $body) = @ARGV;
  $recipient = Encode::decode($codeset, $recipient);
  $body = Encode::decode($codeset, $body);
  ($number, $recipient) = $this->resolve_person($recipient);
  $this->debug_print("Recipient: $recipient");
  $body = $this->transliterate($body);
  $this->debug_print("Message: \n" . Text::Wrap::wrap('  ', '  ', $body));
  $body_len = length $body;
  $this->debug_print("Message length: $body_len");
  $this->quit("Message too long ($body_len > 640)") if $body_len > 640;

  my $remaining = $this->do_login();
  $this->quit('Message limit exceeded') if $remaining == 0;
  my $newmsg_uri = "$proto://www.orange.pl/portal/map/map/message_box?mbox_view=newsms&mbox_edit=new";
  my $res = $this->lwp_visit($ua, $newmsg_uri);
  $this->debug_print('Ready to send...');
  my $uri = "$proto://www.orange.pl/portal/map/map/message_box??_DARGS=/gear/mapmessagebox/smsform.jsp";
  my $a = '/amg/ptk/map/messagebox/formhandlers/MessageFormHandler';
  my $req = $this->lwp_post($uri, 
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
    ]);
  $req->referer($newmsg_uri);
  $this->debug_print('Sending...');
  $res = $ua->request($req);
  $this->http_error($uri) unless $res->is_success;
  my $remaining_after = $this->extract_remaining($res->content);
  $this->quit('Error while sending the message, I guess...') unless $remaining_after < $remaining;
  $this->debug_print('Looks OK');
  $this->debug_print("Number of remaining messages: $remaining_after");
}

main(__PACKAGE__);

__END__

=head1 NAME

orange.pl -- send SMs via orange.pl gateway

=head1 SYNOPSIS

=over 4

=item orange.pl [-s] [--force] I<< <phone-number> >> I<< <text> >>

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

vim:ts=2 sw=2 et
