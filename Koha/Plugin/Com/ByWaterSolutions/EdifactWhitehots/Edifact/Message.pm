package Koha::Plugin::Com::ByWaterSolutions::EdifactEnhanced::Edifact::Message;

# Copyright 2014 PTFS-Europe Ltd
#
# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# Koha is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Koha; if not, see <http://www.gnu.org/licenses>.

use strict;
use warnings;
use utf8;

use Carp qw( carp );

use Koha::Edifact::Line;

sub new {
    my ( $class, $data_array_ref ) = @_;
    my $header       = shift @{$data_array_ref};
    my $bgm          = shift @{$data_array_ref};
    my $msg_function = $bgm->elem(2);
    my $dtm          = [];
    while ( $data_array_ref->[0]->tag eq 'DTM' ) {
        push @{$dtm}, shift @{$data_array_ref};
    }

    my $self = {
        function                 => $msg_function,
        header                   => $header,
        bgm                      => $bgm,
        message_reference_number => $header->elem(0),
        dtm                      => $dtm,
        datasegs                 => $data_array_ref,
    };

    bless $self, $class;
    return $self;
}

sub message_refno {
    my $self = shift;
    return $self->{message_reference_number};
}

sub function {
    my $self         = shift;
    my $msg_function = $self->{bgm}->elem(2);
    if ( $msg_function == 9 ) {
        return 'original';
    }
    elsif ( $msg_function == 7 ) {
        return 'retransmission';
    }
    return;
}

sub message_reference_number {
    my $self = shift;
    return $self->{header}->elem(0);
}

sub message_type {
    my $self = shift;
    return $self->{header}->elem( 1, 0 );
}

sub message_code {
    my $self = shift;
    return $self->{bgm}->elem( 0, 0 );
}

sub docmsg_number {
    my $self = shift;
    return $self->{bgm}->elem(1);
}

sub message_date {
    my $self = shift;

    # usually the first if not only dtm
    foreach my $d ( @{ $self->{dtm} } ) {
        if ( $d->elem( 0, 0 ) eq '137' ) {
            return $d->elem( 0, 1 );
        }
    }
    return;    # this should not happen
}

sub tax_point_date {
    my $self = shift;
    if ( $self->message_type eq 'INVOIC' ) {
        foreach my $d ( @{ $self->{dtm} } ) {
            if ( $d->elem( 0, 0 ) eq '131' ) {
                return $d->elem( 0, 1 );
            }
        }
    }
    return;
}

sub expiry_date {
    my $self = shift;
    if ( $self->message_type eq 'QUOTES' ) {
        foreach my $d ( @{ $self->{dtm} } ) {
            if ( $d->elem( 0, 0 ) eq '36' ) {
                return $d->elem( 0, 1 );
            }
        }
    }
    return;
}

sub shipment_charge {
    my $self = shift;
    my $edifact_plugin = shift;

    # A large number of different charges can be expressed at invoice and
    # item level but the only one koha takes cognizance of is shipment
    # should we wrap all invoice level charges into it??
    if ( $self->message_type eq 'INVOIC' ) {
        my $amt = 0;

        foreach my $moa ( @{ $self->moa_amounts } ) {
            my $qualifier = $moa->{qualifier};
            my $elem_amt  = $moa->{amount};

            # Qualifier 8 = Value Added ( barcodes, lamination, etc. )
            $amt += $elem_amt
              if $qualifier == 8
              && $edifact_plugin->retrieve_data('shipment_charges_moa_8');

            $amt += $elem_amt
              if $qualifier == 79
              && $edifact_plugin->retrieve_data('shipment_charges_moa_79');

            $amt += $elem_amt
              if $qualifier == 124
              && $edifact_plugin->retrieve_data('shipment_charges_moa_124');

            $amt += $elem_amt
              if $qualifier == 131
              && $edifact_plugin->retrieve_data('shipment_charges_moa_131');

            $amt += $elem_amt
              if $qualifier == 304
              && $edifact_plugin->retrieve_data('shipment_charges_moa_304');
        }
        return $amt;
    }
    return;
}

# return NAD fields

sub buyer_ean {
    my $self = shift;
    foreach my $s ( @{ $self->{datasegs} } ) {
        if ( $s->tag eq 'LIN' ) {
            last;
        }
        if ( $s->tag eq 'NAD' ) {
            my $qualifier = $s->elem(0);
            if ( $qualifier eq 'BY' ) {
                return $s->elem( 1, 0 );
            }
        }
    }
    return;
}

sub supplier_ean {
    my $self = shift;
    foreach my $s ( @{ $self->{datasegs} } ) {
        if ( $s->tag eq 'LIN' ) {
            last;
        }
        if ( $s->tag eq 'NAD' ) {
            my $qualifier = $s->elem(0);
            if ( $qualifier eq 'SU' ) {
                return $s->elem( 1, 0 );
            }
        }
    }
    return;

}

sub lineitems {
    my $self = shift;
    if ( $self->{quotation_lines} ) {
        return $self->{quotation_lines};
    }
    else {
        my $items    = [];
        my $item_arr = [];
        foreach my $seg ( @{ $self->{datasegs} } ) {
            my $tag = $seg->tag;
            if ( $tag eq 'LIN' ) {
                if ( @{$item_arr} ) {
                    push @{$items}, Koha::Edifact::Line->new($item_arr);
                }
                $item_arr = [$seg];
                next;
            }
            elsif ( $tag =~ m/^(UNS|CNT|UNT)$/sxm ) {
                if ( @{$item_arr} ) {
                    push @{$items}, Koha::Edifact::Line->new($item_arr);
                }
                last;
            }
            else {
                if ( @{$item_arr} ) {
                    push @{$item_arr}, $seg;
                }
            }
        }
        $self->{quotation_lines} = $items;
        return $items;
    }
}

# Segments that open a group of their own. Meeting a new one of these ends the
# previous group, so a TAX group's context doesn't leak onto the MOA that
# belongs to an ALC further down the summary section.
my %group_openers = map { $_ => 1 } qw( ALC TAX PAT AJT );

# Segments that apply to the whole message rather than to one group, so they
# survive group and section boundaries
my %message_scoped = map { $_ => 1 } qw( CUX );

sub moa_amounts {
    my $self = shift;

    my @amounts;
    if ( $self->message_type eq 'INVOIC' ) {

        # Where in the message we are, and the segments governing the MOA we
        # are about to meet. MOA+8 in particular means "allowance or charge
        # amount" and says nothing on its own about which charge it is, that
        # comes from the ALC it follows.
        my $section = 'header';
        my $line;
        my %group;
        my %message;

        foreach my $s ( @{ $self->{datasegs} } ) {
            my $tag = $s->tag;

            if ( $tag eq 'LIN' ) {
                $section = 'line';
                $line    = $s->elem(0);
                %group   = ();
                next;
            }

            if ( $tag eq 'UNS' ) {
                $section = 'summary';
                undef $line;
                %group = ();
                next;
            }

            if ( $tag ne 'MOA' ) {
                if ( $message_scoped{$tag} ) {
                    $message{$tag} = $s;
                } else {
                    %group = () if $group_openers{$tag};
                    $group{$tag} = $s;
                }
                next;
            }

            push @amounts,
                {
                qualifier => $s->elem( 0, 0 ),
                amount    => $s->elem( 0, 1 ),
                currency  => $s->elem( 0, 2 ),
                section   => $section,
                line      => $line,

                # The MOA is available under its own tag so a filter can match
                # against it ( e.g. MOA element 0.2 for the currency ) as well
                # as against the segments governing it.
                context => { %message, %group, MOA => $s },
                };
        }
    }
    return \@amounts;
}

# Compiled filter regexes, keyed by pattern. These come from plugin config and
# are applied to every MOA in every invoice, so compile each one only once.
my %filter_regex;

sub moa_matches_filters {
    my ( $self, $moa, $filters ) = @_;

    # No filters means the rule matches on its MOA qualifier alone, which is
    # how every rule behaved before filters existed
    return 1 unless $filters && ref $filters eq 'ARRAY' && @{$filters};

    foreach my $filter ( @{$filters} ) {
        return 0 unless _filter_matches( $moa, $filter );
    }

    return 1;
}

sub _filter_matches {
    my ( $moa, $filter ) = @_;

    # Hand-edited configuration can hold anything, ignore what isn't a filter
    return 1 unless ref $filter eq 'HASH';

    my $seg = _trim( $filter->{seg} );

    # A filter with no segment was never filled in, ignore it rather than
    # matching nothing
    return 1 if $seg eq q{};

    my $op  = $filter->{op} || 'eq';
    my $val = _trim( $filter->{val} );
    my @candidates = map { _trim($_) } @{ _filter_candidates( $moa, $seg, $filter->{elem} ) };

    if ( $op eq 'ne' ) {

        # None of the values may match, so a MOA with no such segment passes
        return ( grep { lc $_ eq lc $val } @candidates ) ? 0 : 1;
    }

    if ( $op eq 'contains' ) {
        return ( grep { index( lc $_, lc $val ) >= 0 } @candidates ) ? 1 : 0;
    }

    if ( $op eq 'regex' ) {
        my $re = _filter_regex($val);
        return 0 unless $re;
        return ( grep { $_ =~ $re } @candidates ) ? 1 : 0;
    }

    return ( grep { lc $_ eq lc $val } @candidates ) ? 1 : 0;
}

sub _filter_candidates {
    my ( $moa, $seg, $elem ) = @_;

    # Pseudo-fields are lowercase so they can't collide with a segment tag
    my $pseudo = lc $seg;
    return [ $moa->{section} ] if $pseudo eq 'section';
    return [ $moa->{currency} ] if $pseudo eq 'currency';
    return defined $moa->{line} ? [ $moa->{line} ] : [] if $pseudo eq 'line';

    my $segment = $moa->{context}->{ uc $seg };
    return [] unless $segment;

    $elem = _trim($elem);

    # No element given, so test the value against the whole segment. We can't
    # rely on a vendor putting a code where the standard says it goes.
    return $segment->all_values if $elem eq q{};

    # Anything but N or N.C would read the wrong element while warning on
    # every MOA of every invoice, treat it as matching nothing
    return [] unless $elem =~ /^\d+(?:[.]\d+)?$/;

    my ( $element_number, $component_number ) = split /[.]/, $elem, 2;
    my $value = $segment->value_at( $element_number, $component_number );

    # value_at returns an arrayref for a composite element addressed without a
    # component index
    return ref $value eq 'ARRAY' ? [ @{$value} ] : [$value];
}

sub _filter_regex {
    my $pattern = shift;

    unless ( exists $filter_regex{$pattern} ) {
        $filter_regex{$pattern} = eval { qr/$pattern/i };
    }

    # Report every use, not just the first. A cron run chews through many
    # invoices and the log should say why each one skipped its charges.
    carp "Ignoring invalid MOA filter regex [$pattern]"
        unless $filter_regex{$pattern};

    return $filter_regex{$pattern};
}

sub _trim {
    my $value = shift;

    return q{} unless defined $value;
    return q{} if ref $value;

    $value =~ s/^\s+//;
    $value =~ s/\s+$//;
    return $value;
}

1;
__END__

=head1 NAME

Koha::Edifact::Message

=head1 DESCRIPTION

Class modelling an Edifact Message for parsing

=head1 METHODS

=head2 new

   Passed an array of segments extracts message level info
   and parses lineitems as Line objects

=head2 moa_amounts

   $amounts = $msg->moa_amounts()
   returns an arrayref of every MOA in an invoice message, each with its
   qualifier, amount, currency, section ( header, line or summary ), line
   number and a context hashref of the segments governing it keyed by tag

=head2 moa_matches_filters

   next unless $msg->moa_matches_filters( $moa, $filters )
   returns true if the MOA satisfies every filter in the arrayref. An empty or
   missing filter list always matches.

=head2 _filter_matches

   returns true if one filter matches the MOA

=head2 _filter_candidates

   returns an arrayref of the values a filter should be tested against

=head2 _filter_regex

   compiles and caches a filter regex, returning undef for an invalid pattern

=head2 _trim

   returns the passed value with leading and trailing whitespace removed

=head1 AUTHOR

   Colin Campbell <colin.campbell@ptfs-europe.com>

=head1 COPYRIGHT

   Copyright 2014, PTFS-Europe Ltd
   This program is free software, You may redistribute it under
   under the terms of the GNU General Public License

=cut
