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
use File::Temp qw( tempdir );
use Test::MockModule;
use Test::More tests => 3;

use t::lib::TestBuilder;

use Koha::Database;
use Koha::Plugin::Com::ByWaterSolutions::EdifactEnhanced;
use Koha::Plugin::Com::ByWaterSolutions::EdifactEnhanced::Edifact::Order;
use Koha::Plugin::Com::ByWaterSolutions::EdifactEnhanced::Edifact::Transport;

my $schema  = Koha::Database->new->schema;
my $builder = t::lib::TestBuilder->new;

# Minimal stand-in for a Koha::File::Transport; see
# download_messages_skip_dot_dirs.t for the same approach.
{

    package t::MockFileTransport;

    sub new {
        my ( $class, %args ) = @_;
        return bless {
            files             => $args{files} // [],
            download_attempts => [],
        }, $class;
    }

    sub id                 { return 'mock' }
    sub connect            { return 1 }
    sub disconnect         { return 1 }
    sub download_directory { return undef }
    sub change_directory   { return 1 }
    sub list_files         { return $_[0]->{files} }

    sub download_file {
        my ( $self, $remote, $local ) = @_;
        push @{ $self->{download_attempts} }, $remote;
        open my $fh, '>', $local or return 0;
        print {$fh} 'RAWEDIFACTCONTENT';
        close $fh;
        return 1;
    }

    sub rename_file { return 1 }
}

# filename() only reaches through the first orderline for its basket number
# ( $orderlines->[0]->basketno->basketno ), so stand-ins are enough to exercise
# the suffix logic without the acquisitions fixtures.
{

    package t::MockBasket;
    sub new      { return bless { no => $_[1] }, $_[0] }
    sub basketno { return $_[0]->{no} }
}
{

    package t::MockOrderline;
    sub new      { return bless { basket => $_[1] }, $_[0] }
    sub basketno { return $_[0]->{basket} }
}

sub _new_plugin {
    my (%settings) = @_;
    my $plugin = Koha::Plugin::Com::ByWaterSolutions::EdifactEnhanced->new(
        { enable_plugins => 1, cgi => CGI->new } );
    $plugin->store_data( \%settings ) if %settings;
    return $plugin;
}

subtest 'invoice_file_suffix with a leading period still matches files' => sub {
    plan tests => 3;
    $schema->storage->txn_begin;

    # A vendor entering ".CEI" ( the natural way to type a file extension )
    # used to break the download match: the matcher is m/[.]$suffix$/, so the
    # interpolated leading period became "any char" and foo.CEI no longer matched.
    my $plugin = _new_plugin( invoice_file_suffix => '.CEI' );

    my $vendor = $builder->build_object( { class => 'Koha::Acquisition::Booksellers' } );
    my $edi_account = $builder->build(
        {
            source => 'VendorEdiAccount',
            value  => {
                vendor_id         => $vendor->id,
                file_transport_id => undef,
                plugin => 'Koha::Plugin::Com::ByWaterSolutions::EdifactEnhanced',
            },
        }
    );

    my $transport =
        Koha::Plugin::Com::ByWaterSolutions::EdifactEnhanced::Edifact::Transport
        ->new( $edi_account->{id}, $plugin );

    is( $transport->_get_file_ext('INVOICE'), 'CEI',
        '_get_file_ext strips the leading period from the stored suffix' );

    my $match = "vendor-invoice-$$.CEI";
    my $skip  = "vendor-invoice-$$.txt";
    my $mock  = t::MockFileTransport->new(
        files => [ map { { filename => $_ } } $match, $skip ] );
    $transport->{file_transport} = $mock;
    $transport->working_directory( tempdir( CLEANUP => 1 ) );

    my @downloaded = $transport->download_messages('INVOICE');

    is_deeply( \@downloaded, [$match],
        'the .CEI file is matched and downloaded despite the stored leading period' );
    is_deeply( $mock->{download_attempts}, [$match],
        'the non-matching .txt file is left alone' );

    $schema->storage->txn_rollback;
};

subtest 'order_file_suffix with a leading period does not double the dot' => sub {
    plan tests => 2;
    $schema->storage->txn_begin;

    # filename() does $filename .= ".$suffix"; a stored ".CEO" used to yield
    # ordrNNN..CEO ( two periods ).
    my $plugin = _new_plugin( order_file_suffix => '.CEO' );

    my $orderline = t::MockOrderline->new( t::MockBasket->new(42) );

    # vendor/ean only need to be truthy for the constructor; filename() does
    # not use them.
    my $edi_order =
        Koha::Plugin::Com::ByWaterSolutions::EdifactEnhanced::Edifact::Order->new(
        {
            orderlines => [$orderline],
            vendor     => 'vendor',
            ean        => 'ean',
            plugin     => $plugin,
        }
        );

    is( $edi_order->filename, 'ordr42.CEO',
        'filename has a single separating period before the suffix' );
    unlike( $edi_order->filename, qr/[.][.]/,
        'filename never contains a doubled period' );

    $schema->storage->txn_rollback;
};

subtest 'configure save strips a leading period before storing' => sub {
    plan tests => 2;
    $schema->storage->txn_begin;

    # go_home() prints a redirect to STDOUT; stub it so it does not pollute TAP.
    my $base_mock = Test::MockModule->new('Koha::Plugins::Base');
    $base_mock->mock( go_home => sub { return; } );

    my $plugin = Koha::Plugin::Com::ByWaterSolutions::EdifactEnhanced->new(
        {
            enable_plugins => 1,
            cgi            => CGI->new(
                {
                    save                => 1,
                    order_file_suffix   => '.CEO',
                    invoice_file_suffix => '.CEI',
                }
            ),
        }
    );

    $plugin->configure;

    is( $plugin->retrieve_data('order_file_suffix'), 'CEO',
        'order_file_suffix is stored without the leading period' );
    is( $plugin->retrieve_data('invoice_file_suffix'), 'CEI',
        'invoice_file_suffix is stored without the leading period' );

    $schema->storage->txn_rollback;
};
