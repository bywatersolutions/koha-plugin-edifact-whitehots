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

use Test::More tests => 9;

use Koha::Plugin::Com::ByWaterSolutions::EdifactWhitehots::Edifact;

# A small INVOIC interchange with two LINs and several MOAs at the
# message-summary level. Built inline so the test is self-contained
# and does not depend on Koha's t/edi_testfiles.
my $invoic = join q{},
    q{UNA:+.? },
    q{'UNB+UNOC:3+5013546027173+5013546098818+230101:0000+0000000001},
    q{'UNH+00001+INVOIC:D:96A:UN},
    q{'BGM+380+INV12345+9},
    q{'DTM+137:20240115:102},
    q{'DTM+131:20240114:102},
    q{'NAD+BY+12345::9},
    q{'NAD+SU+5013546027173::9},
    q{'LIN+1++9780123456789:EN},
    q{'QTY+47:2},
    q{'PRI+AAA:9.99},
    q{'MOA+203:19.98},
    q{'LIN+2++9780987654321:EN},
    q{'QTY+47:1},
    q{'PRI+AAA:14.50},
    q{'MOA+203:14.50},
    q{'UNS+S},
    q{'CNT+4:2},
    q{'MOA+79:34.48},
    q{'MOA+8:5.00},
    q{'MOA+124:1.20},
    q{'MOA+131:0.50},
    q{'MOA+304:2.00},
    q{'UNT+19+00001},
    q{'UNZ+1+0000000001'};

my $edi = Koha::Plugin::Com::ByWaterSolutions::EdifactWhitehots::Edifact->new(
    { transmission => $invoic } );
my ($msg) = @{ $edi->message_array };

# Modelled on a real Brodart charge-only invoice: no line items, a GST TAX
# group, then one ALC per value-added charge each followed by its MOA+8.
# MOA+8 is "allowance or charge amount", so the ALC is the only thing that
# says which charge it is.
my $charges = join q{},
    q{UNA:+.? },
    q{'UNB+UNOA:4+1697684:31B+3010805:ZZ+260616:0252+662215},
    q{'UNH+3755+INVOIC:D:96A:UN},
    q{'BGM+380+B7249539+43},
    q{'DTM+137:20260615:102},
    q{'NAD+BY+3010805::31B},
    q{'NAD+SU+1697684::31B},
    q{'CUX+2:USD:4+3:USD:11},
    q{'PAT+1++5:1:D:30},
    q{'DTM+13:20260715:102},
    q{'UNS+S},
    q{'CNT+1:0},
    q{'MOA+86:677.98},
    q{'TAX+7+GST++++S},
    q{'MOA+124:57.62},
    q{'ALC+C++6++C&P},
    q{'MOA+8:397.5},
    q{'ALC+C++6++LFG},
    q{'MOA+8:47.6},
    q{'UNT+19+3755},
    q{'UNZ+1+662215'};

my $charge_edi = Koha::Plugin::Com::ByWaterSolutions::EdifactEnhanced::Edifact->new(
    { transmission => $charges } );
my ($charge_msg) = @{ $charge_edi->message_array };
isa_ok( $msg,
    'Koha::Plugin::Com::ByWaterSolutions::EdifactWhitehots::Edifact::Message',
    'message_array returned a Message object' );

subtest 'header / BGM / DTM accessors' => sub {
    plan tests => 7;

    is( $msg->message_type,    'INVOIC',     'message_type' );
    is( $msg->message_code,    '380',        'message_code (BGM qualifier)' );
    is( $msg->docmsg_number,   'INV12345',   'docmsg_number (invoice number)' );
    is( $msg->function,        'original',   'function: BGM 9 -> original' );
    is( $msg->message_date,    '20240115',   'message_date from DTM 137' );
    is( $msg->tax_point_date,  '20240114',   'tax_point_date from DTM 131' );
    is( $msg->message_refno,   '00001',      'message_refno from UNH' );
};

subtest 'NAD accessors' => sub {
    plan tests => 2;

    is( $msg->buyer_ean,    '12345',         'buyer_ean from NAD+BY' );
    is( $msg->supplier_ean, '5013546027173', 'supplier_ean from NAD+SU' );
};

subtest 'moa_amounts returns every MOA in order' => sub {
    plan tests => 3;

    my $moa = $msg->moa_amounts;
    is( ref $moa, 'ARRAY', 'returns array ref' );

    # MOAs in this message: 203/19.98, 203/14.50, 79/34.48, 8/5.00,
    # 124/1.20, 131/0.50, 304/2.00
    is( scalar @$moa, 7, 'all MOA segments collected' );

    # context holds Segment objects, so compare the scalar fields only. The
    # governing segments are covered by the context subtest below.
    is_deeply(
        [ map { { %{$_}{qw( qualifier amount section line )} } } @{$moa} ],
        [
            { qualifier => '203', amount => '19.98', section => 'line',    line => '1' },
            { qualifier => '203', amount => '14.50', section => 'line',    line => '2' },
            { qualifier => '79',  amount => '34.48', section => 'summary', line => undef },
            { qualifier => '8',   amount => '5.00',  section => 'summary', line => undef },
            { qualifier => '124', amount => '1.20',  section => 'summary', line => undef },
            { qualifier => '131', amount => '0.50',  section => 'summary', line => undef },
            { qualifier => '304', amount => '2.00',  section => 'summary', line => undef },
        ],
        'qualifier/amount pairs preserved, with section and line number'
    );
};

subtest 'shipment_charge sums per plugin shipment_charges_moa_* settings' => sub {
    plan tests => 4;

    # Mock a plugin: shipment_charge calls $plugin->retrieve_data($key)
    my $stub_plugin = sub {
        my %settings = @_;
        bless { _settings => \%settings },
            'Koha::Plugin::Com::ByWaterSolutions::EdifactWhitehots::TestStub';
    };

    {
        no strict 'refs';
        *{'Koha::Plugin::Com::ByWaterSolutions::EdifactWhitehots::TestStub::retrieve_data'}
            = sub { $_[0]->{_settings}->{ $_[1] } };
    }

    # Nothing enabled -> no shipment charge.
    is( $msg->shipment_charge( $stub_plugin->() ),
        0, 'no shipment-charge MOAs enabled returns 0' );

    # Only MOA+8 (Value Added) enabled -> 5.00
    is( $msg->shipment_charge( $stub_plugin->( shipment_charges_moa_8 => 1 ) ),
        5, 'MOA 8 alone returns 5.00' );

    # Only MOA+304 enabled -> 2.00
    is( $msg->shipment_charge( $stub_plugin->( shipment_charges_moa_304 => 1 ) ),
        2, 'MOA 304 alone returns 2.00' );

    # All four shipment-charge qualifiers enabled -> 5 + 1.2 + 0.5 + 2 = 8.7
    my $all = $msg->shipment_charge(
        $stub_plugin->(
            shipment_charges_moa_8   => 1,
            shipment_charges_moa_124 => 1,
            shipment_charges_moa_131 => 1,
            shipment_charges_moa_304 => 1,
        )
    );
    cmp_ok( abs( $all - 8.7 ), '<', 0.0001,
        'all enabled MOAs summed (5 + 1.2 + 0.5 + 2 = 8.7)' );
};

subtest 'lineitems returns one Line per LIN' => sub {
    plan tests => 3;

    my $lines = $msg->lineitems;
    is( ref $lines,   'ARRAY', 'returns array ref' );
    is( scalar @$lines, 2,     'two LINs -> two Line objects' );
    isa_ok( $lines->[0], 'Koha::Edifact::Line',
        'each entry is a Koha::Edifact::Line' );
};

subtest 'moa_amounts records the segments governing each MOA' => sub {
    plan tests => 12;

    my $moa = $charge_msg->moa_amounts;

    is( scalar @{$moa}, 4, 'four MOAs collected' );
    is_deeply(
        [ map { $_->{qualifier} } @{$moa} ],
        [ '86', '124', '8', '8' ],
        'MOAs collected in file order'
    );
    is_deeply(
        [ map { $_->{section} } @{$moa} ],
        [ ('summary') x 4 ],
        'every MOA is in the summary section'
    );

    # The message total precedes both the TAX and the ALC groups
    is( $moa->[0]{context}{TAX}, undef, 'message total has no governing TAX' );
    is( $moa->[0]{context}{ALC}, undef, 'message total has no governing ALC' );

    # MOA+124 belongs to the TAX group, and must not pick up an ALC
    is( $moa->[1]{context}{TAX}->elem(1), 'GST', 'tax amount governed by TAX+7+GST' );
    is( $moa->[1]{context}{ALC}, undef, 'tax amount has no governing ALC' );

    # Each MOA+8 takes the charge code from the ALC immediately before it
    is( $moa->[2]{context}{ALC}->elem( 4, 0 ), 'C&P', 'first charge is C&P' );
    is( $moa->[3]{context}{ALC}->elem( 4, 0 ), 'LFG', 'second charge is LFG' );

    # A new ALC ends the previous group, so TAX does not leak down the section
    is( $moa->[3]{context}{TAX}, undef, 'a later ALC group has dropped the TAX' );

    # CUX applies to the whole message, so it survives every group boundary
    is( $moa->[3]{context}{CUX}->elem( 0, 1 ), 'USD', 'CUX survives to the last MOA' );

    # PAT opened a group before UNS, it must not still be in scope after it
    is( $moa->[0]{context}{PAT}, undef, 'PAT group closed at the section break' );
};

subtest 'moa_matches_filters' => sub {
    plan tests => 17;

    my $moa      = $charge_msg->moa_amounts;
    my $cat_proc = $moa->[2];    # MOA+8 governed by ALC ... C&P
    my $labels   = $moa->[3];    # MOA+8 governed by ALC ... LFG

    # No filters is how every rule behaved before filters existed
    ok( $charge_msg->moa_matches_filters( $cat_proc, undef ), 'undef filters match' );
    ok( $charge_msg->moa_matches_filters( $cat_proc, [] ),    'empty filter list matches' );

    my $alc_is = sub {
        my ( $value, %extra ) = @_;
        return [ { seg => 'ALC', elem => '4.0', op => 'eq', val => $value, %extra } ];
    };

    ok( $charge_msg->moa_matches_filters( $cat_proc, $alc_is->('C&P') ),
        'charge code matched on the governing ALC' );
    ok( !$charge_msg->moa_matches_filters( $labels, $alc_is->('C&P') ),
        'a different charge with the same qualifier is not matched' );
    ok( $charge_msg->moa_matches_filters( $cat_proc, $alc_is->('c&p') ),
        'matching ignores case' );
    ok( $charge_msg->moa_matches_filters( $cat_proc, $alc_is->('  C&P  ') ),
        'matching trims whitespace' );

    # No element given, so the value is tested against the whole segment
    ok( $charge_msg->moa_matches_filters(
            $labels, [ { seg => 'ALC', op => 'eq', val => 'LFG' } ]
        ),
        'blank element tests every component of the segment'
    );
    ok( !$charge_msg->moa_matches_filters(
            $labels, [ { seg => 'ALC', op => 'eq', val => 'JKT' } ]
        ),
        'blank element does not match an absent value'
    );

    ok( $charge_msg->moa_matches_filters(
            $cat_proc, [ { seg => 'ALC', elem => '4.0', op => 'ne', val => 'FGT' } ]
        ),
        'ne passes when the code differs'
    );
    ok( !$charge_msg->moa_matches_filters(
            $cat_proc, [ { seg => 'ALC', elem => '4.0', op => 'ne', val => 'C&P' } ]
        ),
        'ne fails when the code matches'
    );

    # ne means none of the values match, so a MOA with no such segment passes
    ok( $charge_msg->moa_matches_filters(
            $cat_proc, [ { seg => 'TAX', elem => '1', op => 'ne', val => 'GST' } ]
        ),
        'ne passes when the segment is absent entirely'
    );
    ok( !$charge_msg->moa_matches_filters(
            $cat_proc, [ { seg => 'TAX', elem => '1', op => 'eq', val => 'GST' } ]
        ),
        'eq fails when the segment is absent entirely'
    );

    ok( $charge_msg->moa_matches_filters(
            $cat_proc, [ { seg => 'ALC', elem => '4.0', op => 'contains', val => '&' } ]
        ),
        'contains matches a substring'
    );

    ok( $charge_msg->moa_matches_filters(
            $cat_proc, [ { seg => 'ALC', elem => '4.0', op => 'regex', val => '^(C&P|JKT)$' } ]
        ),
        'regex matches one of an alternation'
    );
    ok( !$charge_msg->moa_matches_filters(
            $labels, [ { seg => 'ALC', elem => '4.0', op => 'regex', val => '^(C&P|JKT)$' } ]
        ),
        'regex rejects a code outside the alternation'
    );

    {
        local $SIG{__WARN__} = sub { };
        ok( !$charge_msg->moa_matches_filters(
                $cat_proc, [ { seg => 'ALC', op => 'regex', val => '[' } ]
            ),
            'an invalid regex matches nothing rather than dying'
        );
    }

    # Every filter has to match
    ok( !$charge_msg->moa_matches_filters(
            $cat_proc,
            [   { seg => 'ALC',     elem => '4.0', op => 'eq', val => 'C&P' },
                { seg => 'section', op => 'eq',    val => 'line' },
            ]
        ),
        'a rule fails when only one of two filters matches'
    );
};

subtest 'line-level context, pseudo-fields and defensive matching' => sub {
    plan tests => 16;

    # A LIN group carrying its own ALC charge, with a currency on the MOA and
    # a zero discount percentage to prove a zero can be matched
    my $lines = join q{},
        q{UNA:+.? },
        q{'UNB+UNOC:3+5013546027173+5013546098818+230101:0000+0000000001},
        q{'UNH+00001+INVOIC:D:96A:UN},
        q{'BGM+380+INV-LINES+9},
        q{'DTM+137:20240115:102},
        q{'NAD+BY+12345::9},
        q{'NAD+SU+5013546027173::9},
        q{'LIN+1},
        q{'QTY+47:2},
        q{'ALC+C++6++C&P},
        q{'PCD+3:0},
        q{'MOA+8:12.5:USD},
        q{'LIN+2},
        q{'MOA+203:19.98},
        q{'UNS+S},
        q{'MOA+86:100.00},
        q{'UNT+16+00001},
        q{'UNZ+1+0000000001'};

    my $line_edi = Koha::Plugin::Com::ByWaterSolutions::EdifactEnhanced::Edifact->new(
        { transmission => $lines } );
    my ($line_msg) = @{ $line_edi->message_array };
    my $moa = $line_msg->moa_amounts;

    my $charge = $moa->[0];
    is( $charge->{section},  'line', 'MOA inside a LIN group is line section' );
    is( $charge->{line},     '1',    'line number recorded' );
    is( $charge->{currency}, 'USD',  'currency recorded from the third component' );
    is( $charge->{context}{ALC}->elem( 4, 0 ), 'C&P', 'line-level ALC governs its MOA' );

    ok( $line_msg->moa_matches_filters( $charge, [ { seg => 'section', op => 'eq', val => 'line' } ] ),
        'section filter matches a line MOA' );
    ok( $line_msg->moa_matches_filters( $charge, [ { seg => 'line', op => 'eq', val => '1' } ] ),
        'line filter matches its line number' );
    ok( !$line_msg->moa_matches_filters( $moa->[1], [ { seg => 'line', op => 'eq', val => '1' } ] ),
        'line filter rejects a different line' );
    ok( $line_msg->moa_matches_filters( $charge, [ { seg => 'currency', op => 'eq', val => 'usd' } ] ),
        'currency filter matches ignoring case' );

    # A filter can name the MOA itself, so its own qualifier, amount and
    # currency components are matchable ( MOA+8:12.5:USD here )
    ok( $line_msg->moa_matches_filters( $charge, [ { seg => 'MOA', elem => '0.0', op => 'eq', val => '8' } ] ),
        'the MOA qualifier can be matched on the MOA segment' );
    ok( $line_msg->moa_matches_filters( $charge, [ { seg => 'MOA', elem => '0.2', op => 'eq', val => 'USD' } ] ),
        'the MOA currency can be matched on the MOA segment' );
    ok( !$line_msg->moa_matches_filters( $charge, [ { seg => 'MOA', elem => '0.1', op => 'eq', val => '99.99' } ] ),
        'a non-matching MOA amount is rejected' );

    # PCD+3:0 puts a legitimate zero in component 0.1
    ok( $line_msg->moa_matches_filters( $charge, [ { seg => 'PCD', elem => '0.1', op => 'eq', val => '0' } ] ),
        'an element-addressed zero can be matched' );

    # Nonsense from hand-edited configuration must not warn or die
    ok( !$line_msg->moa_matches_filters( $charge, [ { seg => 'ALC', elem => 'abc', op => 'eq', val => 'C&P' } ] ),
        'a non-numeric element matches nothing' );
    ok( $line_msg->moa_matches_filters( $charge, [ 'FGT' ] ),
        'a filter that is not a hashref is ignored' );

    # The second LIN clears the first group
    is( $moa->[1]{context}{ALC}, undef, 'a new LIN drops the previous ALC' );

    # Nothing but INVOIC has MOA handling
    my $quote = join q{},
        q{UNA:+.? },
        q{'UNB+UNOC:3+5013546027173+5013546098818+230101:0000+0000000002},
        q{'UNH+00002+QUOTES:D:96A:UN},
        q{'BGM+310+Q1+9},
        q{'DTM+137:20240115:102},
        q{'MOA+203:19.98},
        q{'UNT+5+00002},
        q{'UNZ+1+0000000002'};
    my ($quote_msg) = @{
        Koha::Plugin::Com::ByWaterSolutions::EdifactEnhanced::Edifact->new(
            { transmission => $quote } )->message_array
    };
    is_deeply( $quote_msg->moa_amounts, [], 'moa_amounts is empty for a non-invoice' );
};
