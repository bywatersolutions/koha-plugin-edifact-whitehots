#!/usr/bin/perl

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

use Modern::Perl;

use Test::More tests => 7;

use Koha::Plugin::Com::ByWaterSolutions::EdifactWhitehots::Edifact::Segment;

my $class = 'Koha::Plugin::Com::ByWaterSolutions::EdifactWhitehots::Edifact::Segment';

subtest 'tag and simple element parsing' => sub {
    plan tests => 4;

    my $seg = $class->new( { seg_string => "BGM+380+INV00003+9" } );
    isa_ok( $seg, $class );
    is( $seg->tag,    'BGM',      'tag returns 3-char header' );
    is( $seg->elem(0), '380',     'first element parsed' );
    is( $seg->elem(1), 'INV00003', 'second element parsed' );
};

subtest 'composite element components' => sub {
    plan tests => 4;

    # MOA+203:49.95 -> elem(0) is composite [203, 49.95]
    my $seg = $class->new( { seg_string => "MOA+203:49.95" } );
    is( $seg->elem( 0, 0 ), '203',   'qualifier component' );
    is( $seg->elem( 0, 1 ), '49.95', 'amount component' );

    # Bare-string element treated as single component when component=0
    my $bgm = $class->new( { seg_string => "BGM+380+INV00003+9" } );
    is( $bgm->elem( 0, 0 ), '380',
        'string element behaves like single-component when index 0 requested' );
    is( $bgm->elem( 0, 1 ), q{},
        'string element returns empty string for index >0' );
};

subtest 'as_string round-trips parsed segment' => sub {
    plan tests => 2;

    my $simple = $class->new( { seg_string => "BGM+380+INV00003+9" } );
    is( $simple->as_string, 'BGM+380+INV00003+9', 'simple segment round-trips' );

    my $composite = $class->new( { seg_string => "MOA+203:49.95" } );
    is( $composite->as_string, 'MOA+203:49.95',
        'composite element preserved with colon separator' );
};

subtest 'de_escape removes EDIFACT release character' => sub {
    plan tests => 4;

    my $de_escape = \&Koha::Plugin::Com::ByWaterSolutions::EdifactWhitehots::Edifact::Segment::de_escape;

    # ?+ ?: ?' ?? are the four escape sequences
    is( $de_escape->('foo?+bar'), 'foo+bar', 'escaped + de-escaped' );
    is( $de_escape->('foo?:bar'), 'foo:bar', 'escaped : de-escaped' );
    is( $de_escape->("foo?'bar"), "foo'bar", 'escaped apostrophe de-escaped' );
    is( $de_escape->('foo??bar'), 'foo?bar', 'escaped ? de-escaped' );
};

subtest 'out-of-range elements return empty string' => sub {
    plan tests => 2;

    my $seg = $class->new( { seg_string => "BGM+380" } );
    is( $seg->elem(5),     q{}, 'past-end elem returns empty string' );
    is( $seg->elem( 5, 0 ), q{}, 'past-end elem with component returns empty string' );
};

subtest 'all_values flattens every element and component' => sub {
    plan tests => 4;

    # ALC+C++6++C&P is how Brodart labels a value-added charge, so the code
    # sits in the fifth element. _components parses an empty element into an
    # empty arrayref, so empty elements contribute nothing here
    my $alc = $class->new( { seg_string => "ALC+C++6++C&P" } );
    is_deeply( $alc->all_values, [ 'C', '6', 'C&P' ],
        'populated elements flattened in order, empty elements skipped' );

    my $moa = $class->new( { seg_string => "MOA+203:49.95" } );
    is_deeply( $moa->all_values, [ '203', '49.95' ],
        'composite element expanded into its components' );

    # elem() turns a legitimate zero into an empty string, all_values must not
    my $qty = $class->new( { seg_string => "QTY+47:0" } );
    is_deeply( $qty->all_values, [ '47', '0' ], 'a zero component is preserved' );

    my $empty = $class->new( { seg_string => "UNS" } );
    is_deeply( $empty->all_values, [], 'segment with no elements returns empty list' );
};

subtest 'value_at lets a legitimate zero survive' => sub {
    plan tests => 4;

    my $qty = $class->new( { seg_string => "QTY+47:0" } );
    is( $qty->elem( 0, 1 ), q{}, 'elem coerces a zero component to empty string' );
    is( $qty->value_at( 0, 1 ), '0', 'value_at preserves it' );

    my $moa = $class->new( { seg_string => "MOA+203:49.95" } );
    is( $moa->value_at( 0, 0 ), '203', 'component addressing matches elem' );
    is( $moa->value_at( 5, 0 ), q{}, 'out of range still returns empty string' );
};
