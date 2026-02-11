use utf8;
package Support::Schema::Result::Transaction;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Support::Schema::Result::Transaction

=cut

use strict;
use warnings;

use base 'DBIx::Class::Core';

=head1 COMPONENTS LOADED

=over 4

=item * L<DBIx::Class::InflateColumn::DateTime>

=item * L<DBIx::Class::TimeStamp>

=back

=cut

__PACKAGE__->load_components("InflateColumn::DateTime", "TimeStamp");

=head1 TABLE: C<transactions>

=cut

__PACKAGE__->table("transactions");

=head1 ACCESSORS

=head2 id

  data_type: 'integer'
  is_auto_increment: 1
  is_nullable: 0
  sequence: 'support.transactions_id_seq'

=head2 email

  data_type: 'text'
  is_nullable: 0

=head2 first_name

  data_type: 'text'
  is_nullable: 0

=head2 last_name

  data_type: 'text'
  is_nullable: 0

=head2 trans_date

  data_type: 'timestamp'
  is_nullable: 0
  timezone: 'UTC'

=head2 amount_in_cents

  data_type: 'integer'
  is_nullable: 0

=head2 plan_name

  data_type: 'text'
  is_nullable: 1

=head2 plan_code

  data_type: 'text'
  is_nullable: 1

=head2 city

  data_type: 'text'
  is_nullable: 1

=head2 state

  data_type: 'text'
  is_nullable: 1

=head2 zip

  data_type: 'text'
  is_nullable: 0

=head2 country

  data_type: 'text'
  is_nullable: 1

=head2 pref_anonymous

  data_type: 'text'
  is_nullable: 1

=head2 pref_frequency

  data_type: 'text'
  is_nullable: 1

=head2 campaign

  data_type: 'text'
  is_nullable: 1

=head2 pref_newspriority

  data_type: 'integer'
  is_nullable: 1

=head2 wc_status

  data_type: 'text'
  is_nullable: 1

=head2 wc_response

  data_type: 'text'
  is_nullable: 1

=head2 user_agent

  data_type: 'text'
  is_nullable: 1

=head2 wc_send_response

  data_type: 'text'
  is_nullable: 1

=head2 hosted_login_token

  data_type: 'text'
  is_nullable: 1

=head2 appeal_code

  data_type: 'text'
  is_nullable: 1

=head2 pref_lapel

  data_type: 'text'
  is_nullable: 1

=head2 payment_type

  data_type: 'text'
  is_nullable: 1

=head2 phone

  data_type: 'text'
  is_nullable: 1

=head2 transit_number

  data_type: 'text'
  is_nullable: 1

=head2 bank_number

  data_type: 'text'
  is_nullable: 1

=head2 account_number

  data_type: 'text'
  is_nullable: 1

=head2 raiser

  data_type: 'text'
  is_nullable: 1

=head2 referrer

  data_type: 'text'
  is_nullable: 1

=head2 on_behalf_of

  data_type: 'text'
  is_nullable: 1

=head2 on_behalf_of_name_first

  data_type: 'text'
  is_nullable: 1

=head2 on_behalf_of_name_last

  data_type: 'text'
  is_nullable: 1

=head2 address1

  data_type: 'text'
  is_nullable: 1

=head2 fifteenth_year_mailme
data_type: 'text'
is_nullable: 1

=cut

__PACKAGE__->add_columns(
  "id",
  {
    data_type         => "integer",
    is_auto_increment => 1,
    is_nullable       => 0,
    sequence          => "support.transactions_id_seq",
  },
  "email",
  { data_type => "text", is_nullable => 0 },
  "first_name",
  { data_type => "text", is_nullable => 0 },
  "last_name",
  { data_type => "text", is_nullable => 0 },
  "trans_date",
  { data_type => "timestamp", is_nullable => 0, timezone => "UTC" },
  "amount_in_cents",
  { data_type => "integer", is_nullable => 0 },
  "plan_name",
  { data_type => "text", is_nullable => 1 },
  "plan_code",
  { data_type => "text", is_nullable => 1 },
  "city",
  { data_type => "text", is_nullable => 1 },
  "state",
  { data_type => "text", is_nullable => 1 },
  "zip",
  { data_type => "text", is_nullable => 0 },
  "country",
  { data_type => "text", is_nullable => 1 },
  "pref_anonymous",
  { data_type => "text", is_nullable => 1 },
  "pref_frequency",
  { data_type => "text", is_nullable => 1 },
  "campaign",
  { data_type => "text", is_nullable => 1 },
  "pref_newspriority",
  { data_type => "integer", is_nullable => 1 },
  "wc_status",
  { data_type => "text", is_nullable => 1 },
  "wc_response",
  { data_type => "text", is_nullable => 1 },
  "user_agent",
  { data_type => "text", is_nullable => 1 },
  "wc_send_response",
  { data_type => "text", is_nullable => 1 },
  "hosted_login_token",
  { data_type => "text", is_nullable => 1 },
  "appeal_code",
  { data_type => "text", is_nullable => 1 },
  "pref_lapel",
  { data_type => "text", is_nullable => 1 },
  "payment_type",
  { data_type => "text", is_nullable => 1 },
  "phone",
  { data_type => "text", is_nullable => 1 },
  "transit_number",
  { data_type => "text", is_nullable => 1 },
  "bank_number",
  { data_type => "text", is_nullable => 1 },
  "account_number",
  { data_type => "text", is_nullable => 1 },
  "raiser",
  { data_type => "text", is_nullable => 1 },
  "referrer",
  { data_type => "text", is_nullable => 1 },
  "on_behalf_of",
  { data_type => "text", is_nullable => 1 },
  "on_behalf_of_name_first",
  { data_type => "text", is_nullable => 1 },
  "on_behalf_of_name_last",
  { data_type => "text", is_nullable => 1 },
  "address1",
  { data_type => "text", is_nullable => 1 },
);

=head1 PRIMARY KEY

=over 4

=item * L</id>

=back

=cut

__PACKAGE__->set_primary_key("id");


# Created by DBIx::Class::Schema::Loader v0.07042 @ 2016-11-21 10:53:52
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:ef+zB3vq40fcUzy5HM+rSA


# You can replace this text with custom code or comments, and it will be preserved on regeneration
__PACKAGE__->table("support.transactions");
1;
