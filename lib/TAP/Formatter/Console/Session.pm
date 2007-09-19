package TAP::Formatter::Console::Session;

use strict;
use Benchmark;
use File::Spec;
use File::Path;

use TAP::Base;
use Carp;

use vars qw($VERSION @ISA);

@ISA = qw(TAP::Base);

my @ACCESSOR;

BEGIN {

    @ACCESSOR = qw( name formatter parser );

    for my $method (@ACCESSOR) {
        no strict 'refs';
        *$method = sub { shift->{$method} };
    }

    my @CLOSURE_BINDING = qw( header result close_test );

    for my $method (@CLOSURE_BINDING) {
        no strict 'refs';
        *$method = sub {
            my $self = shift;
            return ( $self->{_closures} ||= $self->_closures )->{$method}
              ->(@_);
        };
    }
}

=head1 NAME

TAP::Formatter::Console::Session - Harness output delegate for default console output

=head1 VERSION

Version 2.99_03

=cut

$VERSION = '2.99_03';

=head1 DESCRIPTION

This provides console orientated output formatting for TAP::Harness.

=head1 SYNOPSIS

=cut

=head1 METHODS

=head2 Class Methods

=head3 C<new>

 my %args = (
    formatter => $self,
 )
 my $harness = TAP::Formatter::Console->new( \%args );

The constructor returns a new C<TAP::Formatter::Console> object. The following options are allowed:

=over 4

=item * C<formatter>

=item * C<parser>

=item * C<name>

=back

=cut

sub _initialize {
    my ( $self, $arg_for ) = @_;
    $arg_for ||= {};

    $self->SUPER::_initialize($arg_for);
    my %arg_for = %$arg_for;    # force a shallow copy

    for my $name (@ACCESSOR) {
        $self->{$name} = delete $arg_for{$name};
    }

    if ( my @props = keys %arg_for ) {
        $self->_croak("Unknown arguments to TAP::Harness::new (@props)");
    }

    return $self;
}

=head3 C<header>

Output test preamble

=head3 C<result>

Called by the harness for each line of TAP it receives.

=head3 C<close_test>

Called to close a test session.

=cut

sub _get_output_result {
    my $self = shift;

    my @color_map = (
        {   test => sub { $_->is_test && !$_->is_ok },
            colors => ['red'],
        },
        {   test => sub { $_->is_test && $_->has_skip },
            colors => [
                'white',
                'on_blue'
            ],
        },
        {   test => sub { $_->is_test && $_->has_todo },
            colors => ['white'],
        },
    );

    my $formatter = $self->formatter;
    my $parser    = $self->parser;

    return $formatter->_colorizer
      ? sub {
        my $result = shift;
        for my $col (@color_map) {
            local $_ = $result;
            if ( $col->{test}->() ) {
                $formatter->_set_colors( @{ $col->{colors} } );
                last;
            }
        }
        $formatter->_output( $result->as_string );
        $formatter->_set_colors('reset');
      }
      : sub {
        $formatter->_output( shift->as_string );
      };
}

sub _closures {
    my $self = shift;

    my $parser     = $self->parser;
    my $formatter  = $self->formatter;
    my $show_count = $self->_should_show_count;
    my $pretty     = $formatter->_format_name( $self->name );

    my $really_quiet = $formatter->really_quiet;
    my $quiet        = $formatter->quiet;
    my $verbose      = $formatter->verbose;
    my $directives   = $formatter->directives;
    my $failures     = $formatter->failures;

    my $output_result = $self->_get_output_result;

    my $print_step      = 1;
    my $output          = '_output';
    my $plan            = '';
    my $newline_printed = 0;

    return {
        header => sub {
            $formatter->_output($pretty)
              unless $really_quiet;
        },

        result => sub {
            my $result = shift;

            if ( $result->is_bailout ) {
                $formatter->_failure_output(
                        "Bailout called.  Further testing stopped:  "
                      . $result->explanation
                      . "\n" );
            }

            return if $really_quiet;

            my $planned = $parser->tests_planned;
            my $is_test = $result->is_test;

            # These are used in close_test - but only if $really_quiet
            # is false - so it's safe to only set them here unless that
            # relationship changes.

            $plan = '/' . ( $planned || 0 ) . ' ' unless $plan;
            $output = $formatter->_get_output_method($parser);

            if ( $show_count and $is_test ) {
                my $number = $result->number;

                my $ceiling = $number / 5;
                $print_step *= 2 while $print_step < $ceiling;

                unless ( $number % $print_step ) {
                    $formatter->$output("\r$pretty$number$plan");
                }
            }

            if (!$quiet
                && (   ( $verbose && !$failures )
                    || ( $is_test && $failures && !$result->is_ok )
                    || ( $result->has_directive && $directives ) )
              )
            {
                unless ($newline_printed) {
                    $formatter->_output("\n");
                    $newline_printed = 1;
                }
                $output_result->($result);
                $formatter->_output("\n");
            }
        },

        close_test => sub {
            if ( $show_count && !$really_quiet ) {
                my $spaces = ' ' x
                  length( '.' . $pretty . $plan . $parser->tests_run );
                $formatter->$output("\r$spaces\r$pretty");
            }

            unless ( $parser->has_problems ) {
                unless ($really_quiet) {
                    my $time_report = '';
                    if ( $formatter->timer ) {
                        my $start_time = $parser->start_time;
                        my $end_time   = $parser->end_time;
                        if ( defined $start_time and defined $end_time ) {
                            my $elapsed = $end_time - $start_time;
                            $time_report
                              = $self->time_is_hires
                              ? sprintf( ' %5.3f s', $elapsed )
                              : sprintf( ' %8s s', $elapsed || '<1' );
                        }
                    }

                    $formatter->_output("ok$time_report\n");
                }
            }
            else {
                $self->_output_test_failure($parser);
            }
        },
    };
}

sub _should_show_count {

    # we need this because if someone tries to redirect the output, it can get
    # very garbled from the carriage returns (\r) in the count line.
    return !shift->formatter->verbose && -t STDOUT;
}

sub _output_test_failure {
    my ( $self, $parser ) = @_;
    my $formatter = $self->formatter;
    return if $formatter->really_quiet;

    my $tests_run     = $parser->tests_run;
    my $tests_planned = $parser->tests_planned;

    my $total
      = defined $tests_planned
      ? $tests_planned
      : $tests_run;

    my $passed = $parser->passed;

    # The total number of fails includes any tests that were planned but
    # didn't run
    my $failed = $parser->failed + $total - $tests_run;
    my $exit   = $parser->exit;

    # TODO: $flist isn't used anywhere
    # my $flist  = join ", " => $formatter->range( $parser->failed );

    if ( my $exit = $parser->exit ) {
        my $wstat = $parser->wait;
        my $status = sprintf( "%d (wstat %d, 0x%x)", $exit, $wstat, $wstat );
        $formatter->_failure_output(" Dubious, test returned $status\n");
    }

    if ( $failed == 0 ) {
        $formatter->_failure_output(
            $total
            ? " All $total subtests passed "
            : " No subtests run "
        );
    }
    else {
        $formatter->_failure_output(" Failed $failed/$total subtests ");
        if ( !$total ) {
            $formatter->_failure_output("\nNo tests run!");
        }
    }

    if ( my $skipped = $parser->skipped ) {
        $passed -= $skipped;
        my $test = 'subtest' . ( $skipped != 1 ? 's' : '' );
        $formatter->_output(
            "\n\t(less $skipped skipped $test: $passed okay)");
    }

    if ( my $failed = $parser->todo_passed ) {
        my $test = $failed > 1 ? 'tests' : 'test';
        $formatter->_output(
            "\n\t($failed TODO $test unexpectedly succeeded)");
    }

    $formatter->_output("\n");
}

1;