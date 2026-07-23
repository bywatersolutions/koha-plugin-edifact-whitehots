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
use Test::More tests => 2;

use t::lib::TestBuilder;

use Koha::Database;
use Koha::Plugin::Com::ByWaterSolutions::EdifactEnhanced;
use Koha::Plugin::Com::ByWaterSolutions::EdifactEnhanced::Edifact::Transport;

my $schema  = Koha::Database->new->schema;
my $builder = t::lib::TestBuilder->new;

# Stand-in for a Koha::File::Transport. rename_file() records every
# from/to pair it is handed so the tests can prove which files get the
# mark-processed rename and which are skipped.
{

    package t::MockFileTransport;

    sub new {
        my ( $class, %args ) = @_;
        return bless {
            files           => $args{files} // [],
            rename_attempts => [],
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
        open my $fh, '>', $local or return 0;
        print {$fh} 'RAWEDIFACTCONTENT';
        close $fh;
        return 1;
    }

    sub rename_file {
        my ( $self, $from, $to ) = @_;
        push @{ $self->{rename_attempts} }, [ $from, $to ];
        return 1;
    }
}

sub _new_plugin {
    my (%settings) = @_;
    my $plugin = Koha::Plugin::Com::ByWaterSolutions::EdifactEnhanced->new(
        { enable_plugins => 1, cgi => CGI->new } );
    $plugin->store_data( \%settings ) if %settings;
    return $plugin;
}

# Build a Transport wired to a real (txn-scoped) VendorEdiAccount but with
# its file transport swapped for the mock above.
sub _new_transport {
    my ( $plugin, @files ) = @_;

    my $vendor = $builder->build_object(
        { class => 'Koha::Acquisition::Booksellers' } );
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

    my $mock = t::MockFileTransport->new(
        files => [ map { { filename => $_ } } @files ] );
    $transport->{file_transport} = $mock;
    $transport->working_directory( tempdir( CLEANUP => 1 ) );

    return ( $transport, $mock, $edi_account->{id} );
}

subtest 'files whose suffix already starts with E are not renamed' => sub {
    plan tests => 3;
    $schema->storage->txn_begin;

    # Ingram names invoice files with an .EIN suffix; the C to E status
    # rename would produce the exact same filename, and their server
    # rejects that rename with 'already exists'
    my $plugin = _new_plugin( invoice_file_suffix => 'EIN' );
    my $file   = "vendor-invoice-$$.EIN";
    my ( $transport, $mock, $acct_id ) = _new_transport( $plugin, $file );

    my @downloaded = $transport->download_messages('INVOICE');

    is_deeply( \@downloaded, [$file], 'the file is still downloaded' );
    is_deeply( $mock->{rename_attempts}, [], 'no rename is attempted' );

    my @ingested =
        $schema->resultset('EdifactMessage')
        ->search( { edi_acct => $acct_id } )->get_column('filename')->all;
    is_deeply( \@ingested, [$file], 'the file is still ingested into edifact_messages' );

    $schema->storage->txn_rollback;
};

subtest 'files with a C status suffix are still marked processed' => sub {
    plan tests => 2;
    $schema->storage->txn_begin;

    my $plugin = _new_plugin();
    my $file   = "vendor-quote-$$.CEQ";
    my ( $transport, $mock ) = _new_transport( $plugin, $file );

    my @downloaded = $transport->download_messages('QUOTE');

    is_deeply( \@downloaded, [$file], 'the file is downloaded' );

    ( my $processed = $file ) =~ s/CEQ$/EEQ/;
    is_deeply(
        $mock->{rename_attempts},
        [ [ $file, $processed ] ],
        'the file is renamed with the E status character'
    );

    $schema->storage->txn_rollback;
};
