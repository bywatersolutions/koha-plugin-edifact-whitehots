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
use JSON qw(encode_json);
use Test::More tests => 3;

use t::lib::Mocks;
use t::lib::TestBuilder;

use Koha::Acquisition::Invoice::Adjustments;
use Koha::Acquisition::Invoices;
use Koha::Database;
use Koha::Plugins;
use Koha::Plugin::Com::ByWaterSolutions::EdifactWhitehots;

my $schema  = Koha::Database->new->schema;
my $builder = t::lib::TestBuilder->new;

# edifact_process_invoice routes through Koha::Plugins::Handler->run, which
# requires the plugin's methods to be present in the koha_plugins_methods
# table. InstallPlugins walks every dir under pluginsdir though, which is
# slow and noisy on the kohadev image — so do it once here.
Koha::Plugins->new( { enable_plugins => 1 } )->InstallPlugins(
    { include => ['Koha::Plugin::Com::ByWaterSolutions::EdifactWhitehots'] } );

# Minimal INVOIC interchange. No LIN segments, so process_invoice doesn't
# need any matching aqorders. Three MOAs at the message-summary level
# exercise the configured adjustment rules.
sub _invoic_string {
    my ($supplier_san) = @_;
    return join q{},
        q{UNA:+.? },
        q{'UNB+UNOC:3+} . $supplier_san . q{+5013546098818+230101:0000+0000000001},
        q{'UNH+00001+INVOIC:D:96A:UN},
        q{'BGM+380+INV-MOA-001+9},
        q{'DTM+137:20240115:102},
        q{'DTM+131:20240114:102},
        q{'NAD+BY+12345::9},
        q{'NAD+SU+} . $supplier_san . q{::9},
        q{'UNS+S},
        q{'CNT+4:0},
        q{'MOA+8:5.00},
        q{'MOA+124:1.20},
        q{'MOA+131:0.50},
        q{'UNT+10+00001},
        q{'UNZ+1+0000000001'};
}

sub _new_plugin {
    my (%settings) = @_;
    my $plugin = Koha::Plugin::Com::ByWaterSolutions::EdifactWhitehots->new(
        { enable_plugins => 1, cgi => CGI->new } );
    $plugin->store_data( \%settings ) if %settings;
    return $plugin;
}

sub _build_invoice_message {
    my ( $vendor, $san, $body ) = @_;

    my $file_transport = $builder->build(
        {
            source => 'FileTransport',
            value  => { transport => 'local' }
        }
    );

    my $edi_account = $builder->build(
        {
            source => 'VendorEdiAccount',
            value  => {
                description       => 'TEST',
                vendor_id         => $vendor->id,
                file_transport_id => $file_transport->{file_transport_id},
                plugin            => 'Koha::Plugin::Com::ByWaterSolutions::EdifactWhitehots',
                san               => $san,
                shipment_budget   => undef,
            }
        }
    );

    my $msg = $builder->build(
        {
            source => 'EdifactMessage',
            value  => {
                vendor_id    => $vendor->id,
                edi_acct     => $edi_account->{id},
                message_type => 'INVOIC',
                status       => 'new',
                deleted      => 0,
                filename     => "test-moa-$$-" . int( rand 1_000_000 ) . ".CEI",
                raw_msg      => $body,
                basketno     => undef,
            }
        }
    );

    # process_invoice expects the DBIC schema row (cron passes
    # $schema->resultset('EdifactMessage')->...), so return that directly.
    return $schema->resultset('EdifactMessage')->find( $msg->{id} );
}

subtest 'matching MOA rule creates an invoice adjustment' => sub {
    plan tests => 4;
    $schema->storage->txn_begin;

    my $san    = '5099999000018';
    my $vendor = $builder->build_object(
        { class => 'Koha::Acquisition::Booksellers' } );
    my $budget = $builder->build_object(
        { class => 'Koha::Acquisition::Funds' } );

    my $rules = encode_json( [
        {   moa_qualifier => '8',
            reason        => 'VAS',
            note          => 'value-added services',
            budget_id     => $budget->id,
            encumber_open => 1,
        },
    ] );

    my $plugin = _new_plugin(
        invoice_adjustment_rules => $rules,
        skip_nonmatching_san_suffix => '0',
    );

    my $msg = _build_invoice_message( $vendor, $san, _invoic_string($san) );

    {
        local $SIG{__WARN__} = sub { };
        eval { $plugin->edifact_process_invoice( { invoice => $msg } ); 1 }
            or diag("edifact_process_invoice died: $@");
        ok( !$@, 'edifact_process_invoice ran without dying' );
    }

    my $invoice = Koha::Acquisition::Invoices->search(
        { invoicenumber => 'INV-MOA-001' } )->next;
    ok( $invoice, 'invoice row created' );

    my $adjustments = Koha::Acquisition::Invoice::Adjustments->search(
        { invoiceid => $invoice->invoiceid } );
    is( $adjustments->count, 1, 'one adjustment created from MOA+8 rule' );

    my $adj = $adjustments->next;
    is_deeply(
        {
            adjustment    => sprintf( '%.2f', $adj->adjustment ),
            reason        => $adj->reason,
            note          => $adj->note,
            budget_id     => $adj->budget_id,
            encumber_open => $adj->encumber_open,
        },
        {
            adjustment    => '5.00',
            reason        => 'VAS',
            note          => 'value-added services',
            budget_id     => $budget->id,
            encumber_open => 1,
        },
        'adjustment fields populated from rule + MOA amount'
    );

    $schema->storage->txn_rollback;
};

subtest 'one rule per qualifier; non-matching qualifiers are ignored' => sub {
    plan tests => 3;
    $schema->storage->txn_begin;

    my $san    = '5099999000019';
    my $vendor = $builder->build_object(
        { class => 'Koha::Acquisition::Booksellers' } );

    # Rule for MOA+999 (not in message) -> no adjustments.
    # Rule for MOA+131 (in message)     -> one adjustment.
    my $rules = encode_json( [
        { moa_qualifier => '999', reason => 'NOPE' },
        { moa_qualifier => '131', reason => 'TAX'  },
    ] );

    my $plugin = _new_plugin(
        invoice_adjustment_rules => $rules,
        skip_nonmatching_san_suffix => '0',
    );

    my $msg = _build_invoice_message( $vendor, $san, _invoic_string($san) );

    {
        local $SIG{__WARN__} = sub { };
        eval { $plugin->edifact_process_invoice( { invoice => $msg } ); 1 }
            or diag("edifact_process_invoice died: $@");
        ok( !$@, 'edifact_process_invoice ran without dying' );
    }

    my $invoice = Koha::Acquisition::Invoices->search(
        { invoicenumber => 'INV-MOA-001' } )->next;
    my @adj = Koha::Acquisition::Invoice::Adjustments->search(
        { invoiceid => $invoice->invoiceid } )->as_list;

    is( scalar @adj, 1, 'only the matching qualifier produced an adjustment' );
    is( $adj[0]->reason, 'TAX',
        'adjustment came from the MOA+131 rule, not MOA+999' );

    $schema->storage->txn_rollback;
};

subtest 'no adjustments configured -> no adjustment rows' => sub {
    plan tests => 2;
    $schema->storage->txn_begin;

    my $san    = '5099999000020';
    my $vendor = $builder->build_object(
        { class => 'Koha::Acquisition::Booksellers' } );

    # Default empty config (the configure form sends '[]').
    my $plugin = _new_plugin(
        invoice_adjustment_rules => '[]',
        skip_nonmatching_san_suffix => '0',
    );

    my $msg = _build_invoice_message( $vendor, $san, _invoic_string($san) );

    {
        local $SIG{__WARN__} = sub { };
        eval { $plugin->edifact_process_invoice( { invoice => $msg } ); 1 }
            or diag("edifact_process_invoice died: $@");
        ok( !$@, 'edifact_process_invoice ran without dying' );
    }

    my $invoice = Koha::Acquisition::Invoices->search(
        { invoicenumber => 'INV-MOA-001' } )->next;
    is( Koha::Acquisition::Invoice::Adjustments->search(
            { invoiceid => $invoice->invoiceid } )->count,
        0, 'no adjustments created' );

    $schema->storage->txn_rollback;
};
