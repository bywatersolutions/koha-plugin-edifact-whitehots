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

use Test::More tests => 5;

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
