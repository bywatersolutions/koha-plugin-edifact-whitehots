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

use CGI;
use Test::More tests => 4;

use t::lib::Mocks;
use t::lib::TestBuilder;

use Koha::Acquisition::Orders;
use Koha::Database;
use Koha::Items;
use Koha::Plugin::Com::ByWaterSolutions::EdifactWhitehots;
use Koha::Plugin::Com::ByWaterSolutions::EdifactWhitehots::Edifact::Order;

my $schema  = Koha::Database->new->schema;
my $builder = t::lib::TestBuilder->new;

sub _new_plugin {
    my (%settings) = @_;
    my $plugin = Koha::Plugin::Com::ByWaterSolutions::EdifactWhitehots->new(
        { enable_plugins => 1, cgi => CGI->new } );
    $plugin->store_data( \%settings );
    return $plugin;
}

# Build the minimum acquisitions/EDI fixtures order_line() touches:
# vendor + EDI account, sender library EAN, basket and one orderline.
sub _build_order_fixture {
    my (%args) = @_;
    my $with_item = $args{with_item};

    my $vendor = $builder->build_object(
        {
            class => 'Koha::Acquisition::Booksellers',
            value => { name => 'Test Vendor' },
        }
    );

    # The Edifact::Order constructor uses ->san / ->ean / ->id_code_qualifier
    # on these objects but does not require Koha::Schema relations between
    # them, so a simple Aqbookseller + EdifactEan fixture is enough.
    my $sender_ean = $builder->build(
        {
            source => 'EdifactEan',
            value  => {
                description       => 'TEST',
                ean               => '5099999999990',
                id_code_qualifier => '14',
                branchcode        => undef,
            },
        }
    );
    my $sender_ean_obj = $schema->resultset('EdifactEan')
        ->find( $sender_ean->{ee_id} );

    my $basket = $builder->build_object(
        {
            class => 'Koha::Acquisition::Baskets',
            value => { booksellerid => $vendor->id },
        }
    );
    my $biblio = $builder->build_sample_biblio;

    # Edifact::Order::order_line() walks DBIx::Class belongs_to relations
    # (e.g. $orderline->biblionumber->biblionumber), so we need the schema
    # row, not a Koha::Object wrapper.
    my $orderline_obj = $builder->build_object(
        {
            class => 'Koha::Acquisition::Orders',
            value => {
                basketno     => $basket->basketno,
                biblionumber => $biblio->biblionumber,
                quantity     => 1,
                line_item_id => undef,
            }
        }
    );
    my $orderline =
        $schema->resultset('Aqorder')->find( $orderline_obj->ordernumber );

    if ($with_item) {
        my $item = $builder->build_sample_item(
            {
                biblionumber        => $biblio->biblionumber,
                itemnotes_nonpublic => 'INTERNAL-LIN-XYZ',
            }
        );
        $builder->build(
            {
                source => 'AqordersItem',
                value  => {
                    ordernumber => $orderline_obj->ordernumber,
                    itemnumber  => $item->itemnumber,
                },
            }
        );
    }

    return ( $vendor, $sender_ean_obj, $orderline );
}

sub _build_edifact_order {
    my ( $plugin, $vendor, $sender_ean, $orderline ) = @_;
    return Koha::Plugin::Com::ByWaterSolutions::EdifactWhitehots::Edifact::Order
        ->new(
        {
            orderlines => [$orderline],
            vendor     => $vendor,
            ean        => $sender_ean,
            plugin     => $plugin,
        }
        );
}

subtest 'orderline without an item does not die when lin_use_item_field set' => sub {
    plan tests => 2;
    $schema->storage->txn_begin;
    t::lib::Mocks::mock_preference( 'AcqCreateItem', 'cataloguing' );

    # Regression: pre-015cf92 the LIN block called ->itemnumber on undef.
    my $plugin = _new_plugin(
        lin_use_item_field           => 'itemnotes_nonpublic',
        lin_use_item_field_qualifier => 'IB',
        lin_use_isbn                 => '0',
        lin_use_ean                  => '0',
    );
    my ( $vendor, $sender_ean, $orderline ) = _build_order_fixture( with_item => 0 );
    my $edi_order = _build_edifact_order( $plugin, $vendor, $sender_ean, $orderline );

    eval { $edi_order->order_line( 1, $orderline ); 1 }
        or diag("order_line died: $@");
    ok( !$@, 'order_line returns cleanly with no aqorders_items' );

    my $lin_seg = ( grep { /^LIN\+/ } @{ $edi_order->{segs} } )[0];
    ok( defined $lin_seg, 'a LIN segment was still emitted' );

    $schema->storage->txn_rollback;
};

subtest 'orderline WITH item uses the configured field as LIN id' => sub {
    plan tests => 1;
    $schema->storage->txn_begin;
    t::lib::Mocks::mock_preference( 'AcqCreateItem', 'cataloguing' );

    my $plugin = _new_plugin(
        lin_use_item_field           => 'itemnotes_nonpublic',
        lin_use_item_field_qualifier => 'IB',
    );
    my ( $vendor, $sender_ean, $orderline ) = _build_order_fixture( with_item => 1 );
    my $edi_order = _build_edifact_order( $plugin, $vendor, $sender_ean, $orderline );

    $edi_order->order_line( 1, $orderline );
    my ($lin_seg) = grep { /^LIN\+/ } @{ $edi_order->{segs} };

    # Expect: LIN+1++INTERNAL-LIN-XYZ:IB'
    like(
        $lin_seg,
        qr/^LIN\+1\+\+INTERNAL-LIN-XYZ:IB'/,
        'LIN id_string/code come from the configured item field'
    );

    $schema->storage->txn_rollback;
};

subtest 'orderline whose item was deleted does not die' => sub {
    plan tests => 2;
    $schema->storage->txn_begin;
    t::lib::Mocks::mock_preference( 'AcqCreateItem', 'cataloguing' );

    my $plugin = _new_plugin(
        lin_use_item_field           => 'itemnotes_nonpublic',
        lin_use_item_field_qualifier => 'IB',
        lin_use_isbn                 => '0',
        lin_use_ean                  => '0',
    );
    my ( $vendor, $sender_ean, $orderline ) = _build_order_fixture( with_item => 1 );

    # Deleting an item does not remove its aqorders_items row, so the
    # orderline still points at the now missing itemnumber
    my ($aqorder_item) = $orderline->aqorders_items;
    Koha::Items->find( $aqorder_item->itemnumber )->delete;

    my $edi_order = _build_edifact_order( $plugin, $vendor, $sender_ean, $orderline );

    eval { $edi_order->order_line( 1, $orderline ); 1 }
        or diag("order_line died: $@");
    ok( !$@, 'order_line returns cleanly when the item no longer exists' );

    my $lin_seg = ( grep { /^LIN\+/ } @{ $edi_order->{segs} } )[0];
    ok( defined $lin_seg, 'a LIN segment was still emitted' );

    $schema->storage->txn_rollback;
};

subtest 'orderline without bibnumber returns early' => sub {
    plan tests => 1;
    $schema->storage->txn_begin;

    my $plugin = _new_plugin( lin_use_item_field => 'itemnotes_nonpublic' );
    my ( $vendor, $sender_ean, $orderline ) =
        _build_order_fixture( with_item => 0 );

    # Force the orderline to look like it has no biblio.
    $orderline->update( { biblionumber => undef } );

    my $edi_order = _build_edifact_order( $plugin, $vendor, $sender_ean, $orderline );

    eval { $edi_order->order_line( 1, $orderline ); 1 }
        or diag("order_line died: $@");
    ok( !$@, 'returns without dying when orderline has no biblionumber' );

    $schema->storage->txn_rollback;
};
