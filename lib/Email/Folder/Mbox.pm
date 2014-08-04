use strict;
use warnings;
package Email::Folder::Mbox;
# ABSTRACT: reads raw RFC822 mails from an mbox file
use Carp;
use IO::File;
use Email::Folder::Reader;
use parent 'Email::Folder::Reader';

=head1 SYNOPSIS

This isa Email::Folder::Reader - read about its API there.

=head1 DESCRIPTION

Does exactly what it says on the tin - fetches raw RFC822 mails from an
mbox.

The mbox format is described at http://www.qmail.org/man/man5/mbox.html

We attempt to read an mbox as through it's the mboxcl2 variant,
falling back to regular mbox mode if there is no C<Content-Length>
header to be found.

=head2 OPTIONS

The new constructor takes extra options.

=over

=item C<fh>

When filename is set to C<"FH"> than Email::Folder::Mbox will read mbox
archive from filehandle C<fh> instead from disk file C<filename>.

=item C<eol>

This indicates what the line-ending style is to be.  The default is
C<"\n">, but for handling files with mac line-endings you would want
to specify C<eol =E<gt> "\x0d">

=item C<jwz_From_>

The value is taken as a boolean that governs what is used match as a
message separator.

If false we use the mutt style

 /^From \S+\s+(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)/
 /^From (?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)/;

If true we use

 /^From /

In deference to this extract from L<http://www.jwz.org/doc/content-length.html>

  Essentially the only safe way to parse that file format is to
  consider all lines which begin with the characters ``From ''
  (From-space), which are preceded by a blank line or
  beginning-of-file, to be the division between messages.  That is, the
  delimiter is "\n\nFrom .*\n" except for the very first message in the
  file, where it is "^From .*\n".

  Some people will tell you that you should do stricter parsing on
  those lines: check for user names and dates and so on.  They are
  wrong.  The random crap that has traditionally been dumped into that
  line is without bound; comparing the first five characters is the
  only safe and portable thing to do. Usually, but not always, the next
  token on the line after ``From '' will be a user-id, or email
  address, or UUCP path, and usually the next thing on the line will be
  a date specification, in some format, and usually there's nothing
  after that.  But you can't rely on any of this.

Defaults to false.

=item C<unescape>

This boolean value indicates whenever lines which starts with

 /^>+From /

should be unescaped (= removed leading '>' char). This is needed for
mboxrd and mboxcl variants. But there is no way to detect for used mbox
variant, so default value is false.

=item C<seek_to>

Seek to an offset when opening the mbox.  When used in combination with
->tell you may be able to resume reading, with a trailing wind.

=item <next_message>

This returns next message as string

=item <next_messageref>

This returns next message as ref to string

=item C<tell>

This returns the current filehandle position in the mbox.

=item C<next_from>

This returns the From_ line for next message. Call it before ->next_message.

=back

=cut

sub defaults {
    ( eol => "\n")
}

sub _open_it {
    my $self = shift;
    my $file = $self->{_file};
    my $fh = $self->{fh};

    unless ($file eq "FH" and $fh) {
        # sanity checking
        croak "$file does not exist" unless (-e $file);
        croak "$file is not a file"  unless (-f $file);

        local $/ = $self->{eol};
        $fh = $self->_get_fh($file);
    }

    if ($self->{seek_to}) {
        # we were told to seek.  hope it all goes well
        seek $fh, $self->{seek_to}, 0;
    }
    else {
        my $firstline = <$fh>;
        if ($firstline) {
            croak "$file is not an mbox file" unless $firstline =~ /^From /;
        }
        $self->{from} = $firstline;
    }

    $self->{_fh} = $fh;
}

sub _get_fh {
    my $self = shift;
    my $file = shift;
    my $fh = IO::File->new($file) or croak "Cannot open $file";
    binmode($fh);
    return $fh;
}

use constant debug => 0;
my $count;

sub next_from {
    my $self = shift;
    $self->_open_it unless $self->{_fh};
    return $self->{from};
}

sub next_messageref {
    my $self = shift;

    my $fh = $self->{_fh} || $self->_open_it;
    local $/ = $self->{eol};

    my $mail = '';
    my $prev = '';
    my $last;
    my $inheaders = 1;
    ++$count;
    print "$count starting scanning at line $.\n" if debug;

    while (my $line = <$fh>) {
        if ($line eq $/ && $inheaders) { # end of headers
            print "$count end of headers at line $.\n" if debug;
            $inheaders = 0; # stop looking for the end of headers
            my $pos = tell $fh; # where to go back to if it goes wrong

            # look for a content length header, and try to use that
            if ($mail =~ m/^Content-Length: (\d+)$/mi) {
                $mail .= $prev;
                $prev = '';
                my $length = $1;
                print " Content-Length: $length\n" if debug;
                my $read = '';
                while (my $bodyline = <$fh>) {
                    last if length $read >= $length;
                    # unescape From_
                    $bodyline =~ s/^>(>*From )/$1/ if $self->{unescape};
                    $read .= $bodyline;
                }
                # grab the next line (should be /^From / or undef)
                my $next = <$fh>;
                if (!defined $next || $next =~ /^From /) {
                    $self->{from} = $next;
                    $mail .= "$/$read";
                    return \$mail;
                }
                # seek back and scan line-by-line like the header
                # wasn't here
                print " Content-Length assertion failed '$next'\n" if debug;
                seek $fh, $pos, 0;
            }

            # much the same, but with Lines:
            if ($mail =~ m/^Lines: (\d+)$/mi) {
                $mail .= $prev;
                $prev = '';
                my $lines = $1;
                print " Lines: $lines\n" if debug;
                my $read = '';
                for (1 .. $lines) {
                    my $bodyline = <$fh>;
                    # unescape From_
                    $bodyline =~ s/^>(>*From )/$1/ if $self->{unescape};
                    $read .= $bodyline;
                }
                <$fh>; # trailing newline
                my $next = <$fh>;
                if (!defined $next || $next =~ /^From /) {
                    $self->{from} = $next;
                    $mail .= "$/$read";
                    return \$mail;
                }
                # seek back and scan line-by-line like the header
                # wasn't here
                print " Lines assertion failed '$next'\n" if debug;
                seek $fh, $pos, 0;
            }
        }

        if ($prev eq $/ && ($line =~ $self->_from_line_re)) {
            $mail .= $prev;
            $last = $line;
            last;
        }

        $mail .= $prev;
        $prev = $line;

        # unescape From_
        $prev =~ s/^>(>*From )/$1/ if $self->{unescape};
    }
    print "$count end of message line $.\n" if debug;
    $self->{from} = $last;
    return unless $mail;
    return \$mail;
}

sub next_message {
    my $self = shift;
    my $ref = $self->next_messageref;
    return unless $ref;
    return ${$ref};
}

my @FROM_RE;
BEGIN {
  @FROM_RE = (
    # according to mutt:
    #   A valid message separator looks like:
    #   From [ <return-path> ] <weekday> <month> <day> <time> [ <tz> ] <year>
    qr/^From (?:\S+\s+)?(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)/,

    # though, as jwz rants, only this is reliable and portable
    qr/^From /,
  );
}

sub _from_line_re {
  return $FROM_RE[ $_[0]->{jwz_From_} ? 1 : 0 ];
}

sub tell {
    my $self = shift;
    return tell $self->{_fh};
}

1;
