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

use Test::More tests => 6;

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

    is_deeply(
        $moa,
        [
            { qualifier => '203', amount => '19.98' },
            { qualifier => '203', amount => '14.50' },
            { qualifier => '79',  amount => '34.48' },
            { qualifier => '8',   amount => '5.00' },
            { qualifier => '124', amount => '1.20' },
            { qualifier => '131', amount => '0.50' },
            { qualifier => '304', amount => '2.00' },
        ],
        'qualifier/amount pairs preserved'
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
