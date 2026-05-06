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
use Test::More tests => 6;

use t::lib::Mocks;
use t::lib::TestBuilder;

use Koha::Database;
use Koha::Items;
use Koha::Plugin::Com::ByWaterSolutions::EdifactWhitehots;

my $schema  = Koha::Database->new->schema;
my $builder = t::lib::TestBuilder->new;

# Mock invoice line with controllable quantity (Koha::Edifact::Line stand-in
# — _receipt_items only calls ->quantity on it).
{

    package t::InvLine;
    sub new      { my ( $c, %args ) = @_; bless { %args }, $c }
    sub quantity { $_[0]->{quantity} }
}

# Build the bundle _receipt_items expects: an order with N items linked via
# aqorders_items, all on a basket whose vendor we control.
sub _build_order_with_items {
    my (%args) = @_;
    my $count       = $args{count}       // 1;
    my $framework   = $args{framework}   // q{};
    my $extra_item  = $args{item_values} // {};
    my $extra_order = $args{order_values} // {};

    my $vendor = $builder->build_object( { class => 'Koha::Acquisition::Booksellers' } );
    my $basket = $builder->build_object(
        {
            class => 'Koha::Acquisition::Baskets',
            value => { booksellerid => $vendor->id },
        }
    );
    my $biblio = $builder->build_sample_biblio( { frameworkcode => $framework } );
    my $order  = $builder->build_object(
        {
            class => 'Koha::Acquisition::Orders',
            value => {
                basketno     => $basket->basketno,
                biblionumber => $biblio->biblionumber,
                quantity     => $count,
                unitprice    => 11.11,
                replacementprice => 22.22,
                %$extra_order,
            }
        }
    );

    my @items;
    for ( 1 .. $count ) {
        my $item = $builder->build_sample_item(
            {
                biblionumber => $biblio->biblionumber,
                %$extra_item,
            }
        );
        $builder->build(
            {
                source => 'AqordersItem',
                value  => {
                    ordernumber => $order->ordernumber,
                    itemnumber  => $item->itemnumber,
                },
            }
        );
        push @items, $item;
    }

    return ( $order, \@items, $vendor );
}

sub _new_plugin {
    my (%settings) = @_;
    my $plugin = Koha::Plugin::Com::ByWaterSolutions::EdifactWhitehots->new(
        { enable_plugins => 1, cgi => CGI->new } );
    $plugin->store_data( \%settings ) if %settings;
    return $plugin;
}

subtest 'updates dateaccessioned and booksellerid for each received item' => sub {
    plan tests => 4;
    $schema->storage->txn_begin;
    t::lib::Mocks::mock_preference( 'AcqCreateItem', 'cataloguing' );

    my ( $order, $items, $vendor ) = _build_order_with_items( count => 1 );
    my $item = $items->[0];

    # Pre-clear so we can verify the change.
    $item->dateaccessioned(undef)->booksellerid(undef)->store;

    my $plugin = _new_plugin( no_update_item_price => '1' );    # update_neither

    Koha::Plugin::Com::ByWaterSolutions::EdifactWhitehots::_receipt_items(
        $plugin, $schema,
        t::InvLine->new( quantity => 1 ),
        $order->ordernumber
    );

    my $reread = Koha::Items->find( $item->itemnumber );
    ok( $reread->dateaccessioned, 'dateaccessioned set' );
    is( $reread->booksellerid, $vendor->id,
        'booksellerid copied from basket vendor' );

    is( $reread->price,            $item->price,
        'price unchanged when update_neither' );
    is( $reread->replacementprice, $item->replacementprice,
        'replacementprice unchanged when update_neither' );

    $schema->storage->txn_rollback;
};

subtest 'no_update_item_price update_both copies order prices to item' => sub {
    plan tests => 2;
    $schema->storage->txn_begin;
    t::lib::Mocks::mock_preference( 'AcqCreateItem', 'cataloguing' );

    my ( $order, $items ) = _build_order_with_items(
        count        => 1,
        order_values => { unitprice => 13.13, replacementprice => 26.26 },
    );

    my $plugin = _new_plugin( no_update_item_price => '0' );    # update_both

    Koha::Plugin::Com::ByWaterSolutions::EdifactWhitehots::_receipt_items(
        $plugin, $schema,
        t::InvLine->new( quantity => 1 ),
        $order->ordernumber
    );

    my $reread = Koha::Items->find( $items->[0]->itemnumber );
    cmp_ok( $reread->price,            '==', 13.13,
        'item price set from order unitprice' );
    cmp_ok( $reread->replacementprice, '==', 26.26,
        'item replacementprice set from order' );

    $schema->storage->txn_rollback;
};

subtest 'set_nfl_on_receipt sets notforloan' => sub {
    plan tests => 2;
    $schema->storage->txn_begin;
    t::lib::Mocks::mock_preference( 'AcqCreateItem', 'cataloguing' );

    my ( $order, $items ) = _build_order_with_items(
        count       => 1,
        item_values => { notforloan => 0 },
    );

    my $plugin = _new_plugin(
        no_update_item_price => '1',
        set_nfl_on_receipt   => '7',
    );

    Koha::Plugin::Com::ByWaterSolutions::EdifactWhitehots::_receipt_items(
        $plugin, $schema,
        t::InvLine->new( quantity => 1 ),
        $order->ordernumber
    );

    is( Koha::Items->find( $items->[0]->itemnumber )->notforloan, 7,
        'notforloan set to configured value' );

    # Empty string -> setting is skipped, value preserved
    my ( $order2, $items2 ) = _build_order_with_items(
        count       => 1,
        item_values => { notforloan => 3 },
    );
    my $plugin2 = _new_plugin(
        no_update_item_price => '1',
        set_nfl_on_receipt   => q{},
    );
    Koha::Plugin::Com::ByWaterSolutions::EdifactWhitehots::_receipt_items(
        $plugin2, $schema,
        t::InvLine->new( quantity => 1 ),
        $order2->ordernumber
    );
    is( Koha::Items->find( $items2->[0]->itemnumber )->notforloan, 3,
        'notforloan untouched when set_nfl_on_receipt is empty' );

    $schema->storage->txn_rollback;
};

subtest 'lin_use_item_field_clear_on_invoice clears the configured column' => sub {
    plan tests => 1;
    $schema->storage->txn_begin;
    t::lib::Mocks::mock_preference( 'AcqCreateItem', 'cataloguing' );

    my ( $order, $items ) = _build_order_with_items(
        count       => 1,
        item_values => { itemnotes_nonpublic => 'INTERNAL-LIN-ID-123' },
    );

    my $plugin = _new_plugin(
        no_update_item_price                => '1',
        lin_use_item_field                  => 'itemnotes_nonpublic',
        lin_use_item_field_clear_on_invoice => '1',
    );

    Koha::Plugin::Com::ByWaterSolutions::EdifactWhitehots::_receipt_items(
        $plugin, $schema,
        t::InvLine->new( quantity => 1 ),
        $order->ordernumber
    );

    is( Koha::Items->find( $items->[0]->itemnumber )->itemnotes_nonpublic, q{},
        'configured item column cleared on receipt' );

    $schema->storage->txn_rollback;
};

subtest 'add_itemnote_on_receipt stamps the itemnote' => sub {
    plan tests => 1;
    $schema->storage->txn_begin;
    t::lib::Mocks::mock_preference( 'AcqCreateItem', 'cataloguing' );

    my ( $order, $items ) = _build_order_with_items( count => 1 );

    my $plugin = _new_plugin(
        no_update_item_price    => '1',
        add_itemnote_on_receipt => '1',
    );

    Koha::Plugin::Com::ByWaterSolutions::EdifactWhitehots::_receipt_items(
        $plugin, $schema,
        t::InvLine->new( quantity => 1 ),
        $order->ordernumber
    );

    is( Koha::Items->find( $items->[0]->itemnumber )->itemnotes_nonpublic,
        'Received via EDIFACT', 'itemnote stamped' );

    $schema->storage->txn_rollback;
};

subtest 'caps received items at the invoice line quantity' => sub {
    plan tests => 4;
    $schema->storage->txn_begin;
    t::lib::Mocks::mock_preference( 'AcqCreateItem', 'cataloguing' );

    # Order has 3 linked items, but invoice line says quantity 2 -> only the
    # first two should be touched.
    my ( $order, $items ) = _build_order_with_items(
        count       => 3,
        item_values => { itemnotes_nonpublic => undef },
    );

    my $plugin = _new_plugin(
        no_update_item_price    => '1',
        add_itemnote_on_receipt => '1',
    );

    Koha::Plugin::Com::ByWaterSolutions::EdifactWhitehots::_receipt_items(
        $plugin, $schema,
        t::InvLine->new( quantity => 2 ),
        $order->ordernumber
    );

    my $stamped = 0;
    my $untouched = 0;
    for my $i (@$items) {
        my $note = Koha::Items->find( $i->itemnumber )->itemnotes_nonpublic // q{};
        if ( $note eq 'Received via EDIFACT' ) {
            $stamped++;
        } else {
            $untouched++;
        }
    }
    is( $stamped,   2, '2 items received (matches invoice quantity)' );
    is( $untouched, 1, '1 item left untouched' );

    # And quantity larger than available items processes everyone available
    # without dying.
    my ( $order2, $items2 ) = _build_order_with_items( count => 1 );
    eval {
        Koha::Plugin::Com::ByWaterSolutions::EdifactWhitehots::_receipt_items(
            $plugin, $schema,
            t::InvLine->new( quantity => 5 ),
            $order2->ordernumber
        );
        1;
    };
    ok( !$@, 'no error when quantity exceeds linked item count' );
    is( Koha::Items->find( $items2->[0]->itemnumber )->itemnotes_nonpublic,
        'Received via EDIFACT', 'available item still received' );

    $schema->storage->txn_rollback;
};
