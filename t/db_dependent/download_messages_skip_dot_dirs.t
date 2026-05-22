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

# Stand-in for a Koha::File::Transport. download_messages() only calls the
# handful of methods below. download_file() records every filename it is
# handed *before* doing anything else, so the test can prove . and .. never
# reach it -- without the patch they would.
{

    package t::MockFileTransport;

    sub new {
        my ( $class, %args ) = @_;
        return bless {
            files             => $args{files} // [],
            download_attempts => [],
            rename_attempts   => [],
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

    sub rename_file {
        my ( $self, $from, $to ) = @_;
        push @{ $self->{rename_attempts} }, $from;
        return 1;
    }
}

sub _new_plugin {
    return Koha::Plugin::Com::ByWaterSolutions::EdifactEnhanced->new(
        { enable_plugins => 1, cgi => CGI->new } );
}

# Build a Transport wired to a real (txn-scoped) VendorEdiAccount but with
# its file transport swapped for the mock above. The plugin has no
# invoice_file_suffix stored, so _get_file_ext('INVOICE') returns q{} and
# every listed name reaches the . / .. skip check.
sub _new_transport {
    my (@files) = @_;

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
        ->new( $edi_account->{id}, _new_plugin() );

    my $mock = t::MockFileTransport->new(
        files => [ map { { filename => $_ } } @files ] );
    $transport->{file_transport} = $mock;
    $transport->working_directory( tempdir( CLEANUP => 1 ) );

    return ( $transport, $mock, $edi_account->{id} );
}

subtest 'download_messages skips . and .. directory entries' => sub {
    plan tests => 4;
    $schema->storage->txn_begin;

    my $real1 = "vendor-invoice-$$.CEI";
    my $real2 = ".hidden-$$.CEI";    # dot-prefixed, but NOT . or .. -> kept

    my ( $transport, $mock, $acct_id ) =
        _new_transport( '.', $real1, '..', $real2 );

    my @downloaded = $transport->download_messages('INVOICE');

    is_deeply(
        [ sort @downloaded ],
        [ sort $real1, $real2 ],
        'download_messages returns only the real files'
    );
    is_deeply(
        $mock->{download_attempts},
        [ $real1, $real2 ],
        '. and .. never reach download_file; dot-prefixed real file does'
    );
    is_deeply(
        [ sort @{ $mock->{rename_attempts} } ],
        [ sort $real1, $real2 ],
        'only real files are marked processed on the server'
    );

    my @ingested =
        $schema->resultset('EdifactMessage')
        ->search( { edi_acct => $acct_id } )->get_column('filename')->all;
    is_deeply(
        [ sort @ingested ],
        [ sort $real1, $real2 ],
        'only real files ingested into edifact_messages'
    );

    $schema->storage->txn_rollback;
};

subtest 'download_messages skips . and .. from FTP-style listing lines' => sub {
    plan tests => 2;
    $schema->storage->txn_begin;

    # Koha/File/Transport/FTP.pm can return whole listing lines as the
    # filename; download_messages keeps only the last whitespace-delimited
    # field, which for directory entries is "." or "..".
    my $real = "ftp-invoice-$$.CEI";
    my ( $transport, $mock ) = _new_transport(
        'drwxr-xr-x   2 1000 1000 4096 May 22 12:00 .',
        'drwxr-xr-x   5 1000 1000 4096 May 22 12:00 ..',
        "-rw-r--r--   1 1000 1000  120 May 22 12:00 $real",
    );

    my @downloaded = $transport->download_messages('INVOICE');

    is_deeply( \@downloaded, [$real],
        'only the real file is downloaded from an FTP-style listing' );
    is_deeply( $mock->{download_attempts}, [$real],
        '. and .. resolved from listing lines never reach download_file' );

    $schema->storage->txn_rollback;
};
