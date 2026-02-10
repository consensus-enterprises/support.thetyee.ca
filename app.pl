#!/usr/bin/env perl

use FindBin;
use lib "$FindBin::Bin/local/lib/perl5";

use Mojolicious::Lite;
use Mojo::Log;
use Mojo::UserAgent;
use Data::Dumper;
use DateTime;

use Mojo::URL;
use Try::Tiny;
use Support::Schema;
use XML::Mini::Document;
use Mojo::Util qw(b64_encode url_escape url_unescape hmac_sha1_sum);
use Crypt::CBC;
use MIME::Base64::URLSafe;
use Email::Valid;
use Data::Dumper::HTML qw(dumper_html);
use JSON::XS;
use XML::Hash;

plugin('DefaultHelpers');
plugin 'mail';

my $config = plugin 'JSONConfig';

plugin 'Util::RandomString' => {
    entropy   => 256,
    printable => {
        alphabet => '2345679bdfhmnprtFGHJLMNPRT',
        length   => 20
    }
};

my $ua        = Mojo::UserAgent->new;
my $url       = Mojo::URL->new;
my $subdomain = $config->{'subdomain'};
my $domain    = $subdomain . '.recurly.com/v2/';
my $apikey    = $config->{'privatekey'};
my $API       = 'https://' . $apikey . ':@' . $domain;

hook before_dispatch => sub {
    my $c = shift;
    $c->req->url->base(Mojo::URL->new($config->{'base_url'}));
};

helper schema => sub {
    my $schema = Support::Schema->connect(
        $config->{'pg_dsn'},
        $config->{'pg_user'},
        $config->{'pg_pass'},
    );
    return $schema;
};

helper find_or_new => sub {
    my $self           = shift;
    my $doc            = shift;
    my $dom            = shift;
    my $trans_type     = shift;
    my $params         = shift;
    my $original_params = shift;
    my $dbh            = $self->schema();
    my $result;

    try {
        $result = $dbh->txn_do(
            sub {
                my $rs = $dbh->resultset('Transaction')
                    ->find_or_new( {%$doc} );
                unless ( $rs->in_storage ) {
                    $rs->insert;
                }
                return $rs;
            }
        );
    }
    catch {
        $self->app->log->warn($_);
    };
    return unless $result;

    my $hashref = {};

    $doc->{'id'} = $result->id;
    if ($doc) {
        $hashref->{"local"} = $doc;
    }
    if ( $dom && $trans_type ) {
        $hashref->{$trans_type} = $dom;
    }
    if ($params) {
        $hashref->{'params'} = $params;
    }
    if ($original_params) {
        $hashref->{'original_params'} = $original_params;
    }
    $self->app->log->info("dump of hashref");
    $self->app->log->info( Dumper($hashref) );
    $self->app->log->info("end dump of hashref");

    my $drupal_endpoint = $config->{'drupal_endpoint'};
    my $res = $ua->post(
        $drupal_endpoint => { Accept => '*/*' } => json => $hashref
    );
    $self->app->log->info("return from drupal dump:");
    $self->app->log->info( Dumper($res) );
    $self->app->log->info("end drupal dump:");
    $self->app->log->info("result dump");
    $self->app->log->info( Dumper($result) );
    $self->app->log->info("end result dump");

    return $result;
};

helper search_records => sub {
    my $self      = shift;
    my $resultset = shift;
    my $search    = shift;
    my $schema    = $self->schema;
    my $rs        = $schema->resultset($resultset)->search($search);
    return $rs;
};

helper recurly_get_plans => sub {
    my $self   = shift;
    my $filter = shift;
    my $res = $ua->get( $API . '/plans?per_page=200' => { Accept => 'application/xml' } )->res;
    my $xml   = $res->body;
    my $dom   = Mojo::DOM->new($xml);
    my $plans = $dom->find('plan');

    my $filtered = [];
    foreach my $plan ( $plans->each ) {
        next unless $plan->plan_code->text =~ /$filter/;
        push @$filtered, $plan;
    }
    @$filtered = sort {
        $b->unit_amount_in_cents->CAD->text <=>
            $a->unit_amount_in_cents->CAD->text
    } @$filtered;
    return $filtered;
};

helper recurly_get_account_code => sub {
    my $self         = shift;
    my $account      = shift;
    my $account_href = $account->{'href'};
    my $account_code = $account_href;
    $account_code =~ s!https://$subdomain\.recurly\.com/v2/accounts/!!;
    return $account_code;
};

helper recurly_get_account_details => sub {
    my $self         = shift;
    my $account_code = shift;
    my $res          = $ua->get(
        $API . '/accounts/' . $account_code => { Accept => 'application/xml' }
    )->res;
    my $xml = $res->body;
    my $dom = Mojo::DOM->new($xml);
    return $dom;
};

helper recurly_get_billing_details => sub {
    my $self         = shift;
    my $account_code = shift;
    my $res          = $ua->get(
        $API . '/accounts/' . $account_code . '/billing_info' =>
            { Accept => 'application/xml' }
    )->res;
    my $xml = $res->body;
    my $dom = Mojo::DOM->new($xml);
    return $dom;
};

helper recurly_get_active_subs => sub {
    my $self         = shift;
    my $account_code = shift;
    my $res          = $ua->get(
        $API
            . '/accounts/'
            . $account_code
            . '/subscriptions?state=active' => { Accept => 'application/xml' }
    )->res;
    my $xml        = $res->body;
    my $dom        = Mojo::DOM->new($xml);
    my $ub         = Mojo::UserAgent->new;
    my $collection = $dom->find('subscription');
    my @elements   = $collection->each;
    if ( ( scalar @elements ) >= 2 ) {
        $ub->post(
            $config->{'notify_url'} => json => {
                text =>
                    "Note: Count of subs for someone who just subscribed, account code $account_code are greater than 1, they are "
                        . ( scalar @elements )
            }
        );
    }
    return $dom;
};

# Set the salt and initialize the cipher
my $salt   = $config->{'app_secret'};
my $cipher = Crypt::CBC->new( $salt, 'Blowfish' );

helper raiser_encode => sub {
    my $self           = shift;
    my $email          = shift;
    my $encrypted_data = $cipher->encrypt($email);
    my $safe_data      = urlsafe_b64encode($encrypted_data);
    return $safe_data;
};

helper raiser_decode => sub {
    my $self           = shift;
    my $safe_data      = shift;
    my $encrypted_data = urlsafe_b64decode($safe_data);
    my $decrypted_data = $cipher->decrypt($encrypted_data);
    return $decrypted_data;
};

group {
    under [qw(GET POST)] => '/' => sub {
        my $self = shift;

        # Store the referrer once in the flash
        my $referrer = $self->req->headers->referrer;
        if ( !$self->flash('original_referrer') ) {
            $self->flash( original_referrer => $referrer );
        }

        # Store the campaign-tracking value
        my $campaign = $self->param('campaign') || $self->flash('campaign');
        $self->flash( campaign => $campaign );
        my $raiser = $self->param('raiser') || $self->flash('raiser');
        $self->flash( raiser => $raiser );

        # TODO remove these two
        my $onetime = $self->param('onetime');
        my $amount  = $self->param('amount');

        # TODO remove this statement
        if ( $self->req->method eq 'POST' && $amount =~ /\D/ ) {
            $self->flash(
                {   error   => 'Amount needs to be a whole number',
                    onetime => 'onetime',
                    campaign => $campaign,
                }
            );
            $self->param( { amount => '0' } );
            $amount = '';
            $self->redirect_to('');
        }

        # TODO remove
        my $amount_in_cents;
        if ($amount) {
            $amount_in_cents = $amount * 100;
        }

        # TODO remove this hash
        my $options = {    # RecurlyJS signature options
            'transaction[currency]'        => 'CAD',
            'transaction[amount_in_cents]' => $amount_in_cents,
            'transaction[description]'     =>
                'Support for fact-based independent journalism at The Tyee',
        };

        my $plans = $self->recurly_get_plans(
            $config->{'recurly_get_plans_filter'} );
        my $annual_plans = $self->recurly_get_plans(
            $config->{'recurly_annual_plans_filter'} );
        $self->stash(
            {   plans         => $plans,
                annual_plans  => $annual_plans,
                plans_onetime => $config->{'plans_onetime'},
                amount        => $amount,
                onetime       => $onetime || $self->flash('onetime'),
                error         => $self->flash('error'),
                params        => $self->req->query_params
            }
        );
    };

    my $ab;

    any [qw(GET POST)] => '/' => sub {
        my $ab;
        my $self = shift;
        my $display;
        my $urlstring;
        my $count;

        $ab = 'Dec2025';

        $self->stash( body_id => $ab, );
        $self->flash( appeal_code => $ab );
        $self->stash( display     => $display );
        $self->flash( original_params => $self->req->query_params );
    } => 'Dec2025';

    any [qw(GET POST)] => '/Spring2024' => sub {
        my $ab   = 'Spring2024';
        my $self = shift;
        my $display;

        $self->stash( body_id => $ab, );
        $self->flash( appeal_code => $ab );
        $self->stash( display     => $display );
    } => 'Spring2024';

    any [qw(GET POST)] => '/b' => sub {
        my $ab;
        my $self    = shift;
        my $dt      = DateTime->now;
        my $seconds = $dt->sec;
        my $display;
        $ab = 'evergreen-squeeze';
        if ( $self->param('squeeze') ) {
            $ab      = $self->param('evergreen-squeeze');
            $display = "none";
        }
        if ( $self->param('evergreen') ) {
            $ab      = $self->param('evergreen');
            $display = "block";
        }
        $self->stash( body_id => $ab, );
        $self->flash( appeal_code => $ab );
        $self->stash( display     => $display );
    } => 'evergreen-squeeze';

    any [qw(GET POST)] => '/powermap' => sub {
        my $self = shift;
        $self->stash(
            body_id     => 'powermap',
            appeal_code => 'powermap'
        );
    } => 'powermap';

    any [qw(GET POST)] => '/Spring2023' => sub {
        my $self = shift;
        $self->stash(
            body_id     => 'Spring2023',
            appeal_code => 'Spring2023'
        );
    } => 'Spring2023';

    any [qw(GET POST)] => 'rafemair' => sub {
        my $self = shift;
        $self->stash(
            body_id     => 'RafeMair2017',
            appeal_code => 'RafeMair2017'
        );
        $self->flash( appeal_code => 'RafeMair2017' );
    } => 'RafeMair';

    any [qw(GET POST)] => '/builders' => sub {
        my $self = shift;
        $self->stash(
            body_id     => 'builders',
            appeal_code => 'builders'
        );
    } => 'builders';

    any [qw(GET POST)] => '/builders' => sub {
        my $self = shift;
        $self->stash(
            body_id     => 'builders',
            appeal_code => 'builders'
        );
    } => 'builders';

    any [qw(GET POST)] => '/dec2018' => sub {
        my $self = shift;
        $self->stash(
            body_id     => 'dec2018',
            appeal_code => 'dec2018'
        );
    } => 'DecBuilderCamp2019';

    any [qw(GET POST)] => '/national' => sub {
        my $self = shift;
        $self->stash(
            body_id     => 'national',
            appeal_code => 'national'
        );
    } => 'national';

    any [qw(GET POST)] => '/evergreen' => sub {
        my $self = shift;
        $self->stash(
            body_id     => 'evergreen',
            appeal_code => 'evergreen',
            display     => 'block'
        );
    } => 'evergreen';

    any [qw(GET POST)] => '/evergreen-squeeze' => sub {
        my $self = shift;
        $self->stash(
            body_id     => 'evergreen-squeeze',
            appeal_code => 'evergreen-squeeze',
            display     => 'block'
        );
    } => 'evergreen-squeeze';

    any [qw(GET POST)] => '/evergreen-unsqueeze' => sub {
        my $self = shift;
        $self->stash(
            body_id     => 'evergreen-unsqueeze',
            appeal_code => 'evergreen-unsqueeze',
            display     => 'block'
        );
    } => 'evergreen-unsqueeze';

    any [qw(GET POST)] => '/iframe' => sub {
        my $self = shift;
        $self->flash( iframe => 'yes' );

        $self->stash(
            body_id     => 'iframe',
            appeal_code => 'iframe',
            display     => 'block'
        );

        $self->stash( 'iframe' => 1 );
        $self->flash( 'iframe' => 1 );

    } => 'iframe';

    any [qw(GET POST)] => '/election2017-2' => sub {
        my $self = shift;
        $self->stash(
            body_id     => 'election2017-2',
            appeal_code => 'election2017-2'
        );
        $self->flash( appeal_code => 'election2017-2' );
    } => 'election2017-2';

    any [qw(GET POST)] => '/election2015' => sub {
        my $self = shift;
        $self->stash(
            body_id     => 'election2015',
            appeal_code => 'election2015'
        );
        $self->flash( appeal_code => 'election2015' );
    } => 'election2015';

    any [qw(GET POST)] => '/voices' => sub {
        my $self = shift;
        $self->stash(
            body_id     => 'voices',
            appeal_code => 'voices'
        );
        $self->flash( appeal_code => 'voices' );
    } => 'voices';
};

# New route for processing EFT/ACH subscriptions
any [qw(GET POST)] => '/process_bank' => sub {
    my $self        = shift;
    my $params      = $self->flash('params');
    my $campaign    = $self->flash('campaign');
    my $appeal_code = $self->flash('appeal_code');
    my $referrer    = $self->flash('original_referrer');
    my $raiser      = $self->flash('raiser');
    my $dt          = DateTime->now;
    $dt->set_time_zone('Europe/London');
    my $trans_date      = $dt->ymd . ' ' . $dt->hms;
    my $states          = $params->{'state'};
    my $original_params = $self->flash('original_params');

    my $state;

    if ( ref($states) && @$states ) {
        if ( @$states[0] )      { $state = @$states[0] }
        elsif ( @$states[1] )   { $state = @$states[1] }
        elsif ( $params->{'state'} ) { $state = $params->{'state'} }
    }
    else {
        $state = $params->{'state'};
    }

    my $transaction_details = {
        email              => $params->{'email'},
        phone              => $params->{'phone'},
        first_name         => $params->{'first-name'},
        last_name          => $params->{'last-name'},
        hosted_login_token => 'Bank transaction. Not applicable',
        trans_date         => $trans_date,
        address1           => $params->{'address1'},
        city               => $params->{'city'},
        state              => $state,
        country            => $params->{'country'},
        zip                => $params->{'postal-code'},
        amount_in_cents    => $params->{'amount-in-cents'},
        plan_name          => $params->{'plan-name'},
        plan_code          => $params->{'plan-code'},
        payment_type       => $params->{'payment-type'},
        transit_number     => $params->{'transit-number'},
        bank_number        => $params->{'bank-number'},
        account_number     => $params->{'account-number'},
        campaign           => $campaign,
        (   defined $raiser
            ? ( 'raiser' => $self->raiser_decode($raiser) )
            : ()
        ),
        appeal_code => $appeal_code,
        referrer    => $referrer,
        user_agent  => $self->req->headers->user_agent,
    };

    my $res = $ua->post(
        $config->{'iats_process_proxy'} => { Accept => '*/*' } =>
            form => $transaction_details
    );
    app->log->debug("res->body from iats proxy dump:");
    app->log->debug( Dumper( $res->res->content->asset->{"content"} ) );
    app->log->debug("end res->body from iats proxy dump:");

    my $json_return = decode_json( $res->res->content->asset->{"content"} );

    my $result = $self->find_or_new(
        $transaction_details,
        $json_return,
        "IATS",
        $params,
        $original_params
    );
    $transaction_details->{'id'} = $result->id;
    $self->flash( { transaction_details => $transaction_details, } );

    $self->redirect_to('/perks');
};

post '/get_update_link' => sub {
    my $self = shift;
    my $email;
    my $res;
    my $text;

    $email = {
        'account' => {
            'account_code' => $self->param('email')
        }
    };

    $res = $ua->get(
        $API . 'accounts/' . $self->param('email') =>
            { 'Content-Type' => 'application/xml', Accept => '*/*' }
    );

    my $xml = $res->res->content->asset->{content};

    my $dom = Mojo::DOM->new($xml);
    if ( $dom->at('error') ) {
        my $error = $dom->at('error')->text;
        $self->flash( { error => $error } );
        $text
            .= "Your email address was not found in our system. Please send an email to builders AT thetyee DOT ca or give us a call to update your account.";
    }
    else {

        if ( $dom->at('hosted_login_token')->text
            && $dom->at('hosted_login_token')->text ne '' )
        {
            $text
                .= "You have been sent an email with a link to update your account with us.";

            $self->mail(
                from => 'builders@thetyee.ca',
                type => 'text/html',
                to   => $self->param('email'),
                bcc  => 'builders@thetyee.ca',
                subject =>
                    'The Tyee - Modify Your Builder Account',
                data =>
                    'You appear to have requested your sign-in for your builder account with The Tyee at https://support.thetyee.ca.  You can sign in to your account by visiting the following link: https://'
                        . $subdomain
                        . '.recurly.com/account/'
                        . $dom->at('hosted_login_token')->text
                        . "\n \n <br><br>"
                        . 'Note that for security reasons, if you are updating a card you have to re-input the entire card, expiry and security code (even if only the expiry has changed). If this was sent by mistake you can delete or ignore it - we only send this information to the email registered on the account.',
            );
        }
        else {
            # no hosted_login_token; just generic message
        }
    }

    $self->render(
        template => 'default',
        content  => $text,
        title    => "The Tyee | Get account management link",
        body_id  => ''
    );
};

post '/create-payment-intent' => sub {
    my $self = shift;

    my $json            = $self->req->json || {};
    my $amount_in_cents = $json->{amount_in_cents} || 0;
    my $email           = $json->{email}           || '';

    unless ( $amount_in_cents && $amount_in_cents =~ /^\d+$/ ) {
        $self->render( status => 400, json => { error => 'Invalid amount' } );
        return;
    }

    my $stripe_secret = $config->{'stripe_secret_key'};
    unless ($stripe_secret) {
        $self->app->log->error("Missing stripe_secret_key in config");
        $self->render(
            status => 500,
            json   => { error => 'Payment configuration error' }
        );
        return;
    }

    my $description
        = 'Support for fact-based independent journalism at The Tyee';

    my $tx = $ua->post(
        'https://api.stripe.com/v1/payment_intents' => {
            Authorization => "Bearer $stripe_secret"
        } => form => {
            amount                        => $amount_in_cents,
            currency                      => 'cad',
            'automatic_payment_methods[enabled]' => 'true',
            description                   => $description,
            ( $email ? ( 'receipt_email' => $email ) : () ),
        }
    );
    my $res = $tx->res;

    if ( $res->code && $res->code =~ /^2/ ) {
        my $pi = $res->json;
        $self->render( json => { clientSecret => $pi->{client_secret} } );
    }
    else {
        $self->app->log->error(
            "Stripe PI error ["
                . ( $res->code // 'no-code' )
                . "]: "
                . $res->body );
        $self->render(
            status => 500,
            json   => {
                error => 'Unable to create payment. Please try again.'
            }
        );
    }
};

post '/create-setup-intent' => sub {
    my $self = shift;

    my $json  = $self->req->json || {};
    my $email = $json->{email} || '';
    my $name  = $json->{name}  || '';

    my $stripe_secret = $config->{'stripe_secret_key'};
    unless ($stripe_secret) {
        $self->app->log->error("Missing stripe_secret_key in config");
        $self->render(
            status => 500,
            json   => { error => 'Payment configuration error' }
        );
        return;
    }

    # 1) Create Customer
    my $tx_customer = $ua->post(
        'https://api.stripe.com/v1/customers' => {
            Authorization => "Bearer $stripe_secret"
        } => form => {
            ( $email ? ( email => $email ) : () ),
            ( $name  ? ( name  => $name )  : () ),
        }
    );
    my $res_customer = $tx_customer->res;

    if ( !$res_customer->code || $res_customer->code !~ /^2/ ) {
        $self->app->log->error(
            "Stripe customer error ["
                . ( $res_customer->code // 'no-code' )
                . "]: "
                . $res_customer->body );
        $self->render(
            status => 500,
            json   => { error => 'Unable to create customer.' }
        );
        return;
    }

    my $customer    = $res_customer->json;
    my $customer_id = $customer->{id};

    # 2) Create SetupIntent for off-session card
    my $tx_si = $ua->post(
        'https://api.stripe.com/v1/setup_intents' => {
            Authorization => "Bearer $stripe_secret"
        } => form => {
            customer                  => $customer_id,
            'payment_method_types[0]' => 'card',
            'usage'                   => 'off_session',
        }
    );
    my $res_si = $tx_si->res;

    if ( !$res_si->code || $res_si->code !~ /^2/ ) {
        $self->app->log->error(
            "Stripe SetupIntent error ["
                . ( $res_si->code // 'no-code' )
                . "]: "
                . $res_si->body );
        $self->render(
            status => 500,
            json   => { error => 'Unable to create setup intent.' }
        );
        return;
    }

    my $si = $res_si->json;
    $self->render(
        json => {
            clientSecret => $si->{client_secret},
            customerId   => $customer_id,
        }
    );
};

# New route for processing the form post with Stripe + Recurly PayPal
post '/process_transaction' => sub {
    my $self = shift;

    # Capture values from flash
    my $campaign     = $self->flash('campaign');
    my $appeal_code  = $self->flash('appeal_code');
    my $referrer     = $self->flash('original_referrer');
    my $raiser       = $self->flash('raiser');
    my $payment_type = $self->param('payment-type') || 'card';

    my $amount               = $self->param('amount');
    my $amount_in_cents      = $self->param('amount-in-cents');
    my $unit_amount_in_cents = $self->param('unit-amount-in-cents');
    my $first_name           = $self->param('first-name');
    my $last_name            = $self->param('last-name');
    my $address              = $self->param('address1');
    my $city                 = $self->param('city');
    my $state                = $self->param('state');
    my $country              = $self->param('country');
    my $postal               = $self->param('postal-code');
    my $email                = $self->param('email');
    my $phone                = $self->param('phone');
    my $plan_name            = $self->param('plan-name');
    my $plan_code            = $self->param('plan-code');
    my $params               = $self->req->body_params->to_hash;
    my $original_params      = $self->flash('original_params');

    my $stripe_secret = $config->{'stripe_secret_key'};

    # ---------- 1) Bank / EFT: unchanged, still goes through /process_bank ----------
    if ( $payment_type eq 'bank' ) {
        $self->flash(
            {   params            => $params,
                campaign          => $campaign,
                raiser            => $raiser,
                appeal_code       => $appeal_code,
                original_referrer => $referrer,
                original_params   => $original_params,
            }
        );
        $self->redirect_to('process_bank');
        return;
    }

    # ---------- 2) PayPal via Recurly (original Recurly flow, but PayPal-only) ----------
    if ( $payment_type eq 'paypal' ) {

        my $token = $self->param('recurly-token');

        unless ($token) {
            $self->app->log->error("Missing recurly-token for PayPal");
            $self->flash(
                {   error =>
                    'We could not process your PayPal payment. Please try again.'
                }
            );
            $self->redirect_to('/');
            return;
        }

        my $xmldoc = XML::Mini::Document->new();
        my $transaction;
        my $res;

        if ( !$plan_code && $amount_in_cents ) {    # one-time transaction
            $transaction = {
                'transaction' => {
                    'amount_in_cents' => $amount_in_cents,
                    'currency'        => 'CAD',
                    'account'         => {
                        'account_code' => lc $email,
                        'first_name'   => $first_name,
                        'last_name'    => $last_name,
                        'email'        => lc $email,
                        'billing_info' => { 'token_id' => $token }
                    }
                }
            };
            $xmldoc->fromHash($transaction);
            my $transxml = $xmldoc->toString;

            $res = $ua->post(
                $API . 'transactions' => {
                    'Content-Type' => 'application/xml',
                    Accept         => '*/*'
                } => $transxml
            )->res;
        }
        else {    # subscription (monthly/annual)
            $transaction = {
                'subscription' => {
                    'plan_code'            => $plan_code,
                    'currency'             => 'CAD',
                    'unit_amount_in_cents' => $unit_amount_in_cents,
                    'account'              => {
                        'account_code' => lc $email,
                        'first_name'   => $first_name,
                        'last_name'    => $last_name,
                        'email'        => lc $email,
                        'billing_info' => { 'token_id' => $token }
                    }
                }
            };
            $xmldoc->fromHash($transaction);
            my $transxml = $xmldoc->toString;

            $res = $ua->post(
                $API . 'subscriptions' => {
                    'Content-Type' => 'application/xml',
                    Accept         => '*/*'
                } => $transxml
            )->res;
        }

        my $xml = $res->body;

        $self->app->log->info(
            "dump of Recurly PayPal transaction or subscription:");
        $self->app->log->info( Dumper $xml );
        $self->app->log->info("end of dump:");

        my $dom = Mojo::DOM->new($xml);
        if ( $dom->at('error') ) {    # We got an error message back
            my $error = $dom->at('error')->text;
            $self->flash( { error => $error } );
            $self->redirect_to('/');
            return;
        }
        else {                        # Otherwise, store the transaction

            my $account_code
                = $self->recurly_get_account_code( $dom->at('account') );
            my $account      = $self->recurly_get_account_details($account_code);
            my $activesubs   = $self->recurly_get_active_subs($account_code);
            my $billing_info = $self->recurly_get_billing_details($account_code);

            my $transaction_details = {
                email      => $email,
                first_name => $first_name,
                last_name  => $last_name,

                hosted_login_token =>
                    $account->at('hosted_login_token')
                        ? $account->at('hosted_login_token')->text
                        : '',

                trans_date => $dom->at('created_at')
                    ? $dom->at('created_at')->text
                    : $dom->at('activated_at')
                    ? $dom->at('activated_at')->text
                    : '',

                address1        => $address,
                city            => $city,
                state           => $state,
                country         => $country,
                zip             => $postal,
                amount_in_cents => $amount_in_cents,
                plan_name       => $plan_name,
                plan_code       => $plan_code,
                campaign        => $campaign,
                (
                    defined $raiser
                        ? ( 'raiser' => $self->raiser_decode($raiser) )
                        : ()
                ),
                appeal_code  => $appeal_code,
                referrer     => $referrer,
                payment_type => $payment_type,    # 'paypal'
                phone        => $phone,
                user_agent   => $self->req->headers->user_agent,
            };

            my $xml_converter = XML::Hash->new();
            my $xml_hash
                = $xml_converter->fromXMLStringtoHash($xml);

            my $result = $self->find_or_new(
                $transaction_details,
                $xml_hash,
                "RECURLY",
                $params,
                $original_params
            );
            $transaction_details->{'id'} = $result->id;
            $self->flash(
                { transaction_details => $transaction_details } );

            if ( $self->stash('iframe') | $self->flash('iframe') ) {
                $self->stash( 'iframe' => 1 );
                $self->flash( 'iframe' => 1 );
            }

            $self->redirect_to('/perks');
            return;
        }
    }

    # ---------- 3) ONE-TIME card: no plan_code + amount_in_cents => Stripe PaymentIntent ----------
    if ( !$plan_code && $amount_in_cents ) {
        my $payment_intent_id = $self->param('payment_intent_id');
        unless ($payment_intent_id) {
            $self->app->log->error("Missing payment_intent_id for one-time");
            $self->flash(
                {   error =>
                    'We could not verify your payment. Please try again.'
                }
            );
            $self->redirect_to('/');
            return;
        }

        unless ($stripe_secret) {
            $self->app->log->error("Missing stripe_secret_key in config");
            $self->flash(
                {   error =>
                    'Payment configuration error. Please contact support.'
                }
            );
            $self->redirect_to('/');
            return;
        }

        my $res = $ua->get(
            "https://api.stripe.com/v1/payment_intents/$payment_intent_id"
                => { Authorization => "Bearer $stripe_secret" }
        )->res;

        if ( !$res->code || $res->code !~ /^2/ ) {
            $self->app->log->error(
                "Stripe retrieve PI error ["
                    . ( $res->code // 'no-code' )
                    . "]: "
                    . $res->body );
            $self->flash(
                {   error =>
                    'We could not verify your payment. Please try again.'
                }
            );
            $self->redirect_to('/');
            return;
        }

        my $pi = $res->json;
        if ( !$pi || $pi->{status} ne 'succeeded' ) {
            $self->app->log->error(
                "PaymentIntent not succeeded: id=$payment_intent_id, status="
                    . ( $pi->{status} || 'unknown' ) );
            $self->flash(
                {   error =>
                    'Your payment did not complete. Please try again.'
                }
            );
            $self->redirect_to('/');
            return;
        }

        my $charged_amount_in_cents = $pi->{amount} || $amount_in_cents;

        my $trans_date = '';
        if ( defined $pi->{created} ) {
            my $dt = DateTime->from_epoch( epoch => $pi->{created} );
            $dt->set_time_zone('Europe/London');
            $trans_date = $dt->ymd . ' ' . $dt->hms;
        }

        my $transaction_details = {
            email              => $email,
            first_name         => $first_name,
            last_name          => $last_name,
            hosted_login_token => '',
            trans_date         => $trans_date,
            address1           => $address,
            city               => $city,
            state              => $state,
            country            => $country,
            zip                => $postal,
            amount_in_cents    => $charged_amount_in_cents,
            plan_name          => $plan_name,
            plan_code          => $plan_code,
            campaign           => $campaign,
            (
                defined $raiser
                    ? ( 'raiser' => $self->raiser_decode($raiser) )
                    : ()
            ),
            appeal_code  => $appeal_code,
            referrer     => $referrer,
            payment_type => 'one_time',
            phone        => $phone,
            user_agent   => $self->req->headers->user_agent,
            stripe_payment_intent_id => $payment_intent_id,
            stripe_currency          => $pi->{currency},
        };

        my $noxml = '<?xml version="1.0" ?>'
            . "\n"
            . '<metadata>'
            . "\n"
            . '</metadata>';
        my $xml_converter = XML::Hash->new();
        my $xml_hash
            = $xml_converter->fromXMLStringtoHash($noxml);

        my $result = $self->find_or_new(
            $transaction_details,
            $xml_hash,
            "STRIPE_ONE_TIME",
            $params,
            $original_params
        );
        $transaction_details->{'id'} = $result->id;
        $self->flash( { transaction_details => $transaction_details } );

        if ( $self->stash('iframe') | $self->flash('iframe') ) {
            $self->stash( 'iframe' => 1 );
            $self->flash( 'iframe' => 1 );
        }

        $self->redirect_to('/perks');
        return;
    }

    # ---------- 4) RECURRING card: plan_code present => Stripe subscription ----------
    my $stripe_customer_id       = $self->param('stripe_customer_id');
    my $stripe_payment_method_id = $self->param('stripe_payment_method_id');

    unless ( $stripe_secret && $stripe_customer_id && $stripe_payment_method_id )
    {
        $self->app->log->error(
            "Missing Stripe info for subscription (cust or pm or secret)");
        $self->flash(
            {   error =>
                'We could not set up your subscription. Please try again.'
            }
        );
        $self->redirect_to('/');
        return;
    }

    unless ( $amount_in_cents && $amount_in_cents =~ /^\d+$/ ) {
        $self->app->log->error(
            "Missing or invalid amount_in_cents for subscription");
        $self->flash(
            {   error =>
                'We could not set up your subscription amount. Please try again.'
            }
        );
        $self->redirect_to('/');
        return;
    }

    my $interval = 'month';
    if ( $plan_code =~ /annual|year/i || $plan_code eq 'custom_annual' ) {
        $interval = 'year';
    }

    my $product_key
        = $interval eq 'year'
        ? 'stripe_product_annual_dynamic'
        : 'stripe_product_monthly_dynamic';

    my $product_id = $config->{$product_key};
    unless ($product_id) {
        $self->app->log->error(
            "Missing $product_key in config for subscription");
        $self->flash(
            {   error =>
                'We could not set up your subscription. Please contact support.'
            }
        );
        $self->redirect_to('/');
        return;
    }

    my %subscription_form = (
        customer                                     => $stripe_customer_id,
        'items[0][price_data][currency]'            => 'cad',
        'items[0][price_data][recurring][interval]' => $interval,
        'items[0][price_data][unit_amount]'         => $amount_in_cents,
        'items[0][price_data][product]'             => $product_id,
        'default_payment_method'                    => $stripe_payment_method_id,
        'collection_method'                         => 'charge_automatically',
        'payment_behavior'                          => 'allow_incomplete',
        'proration_behavior'                        => 'none',
    );

    $subscription_form{'metadata[plan_code]'}   = $plan_code
        if defined $plan_code;
    $subscription_form{'metadata[plan_name]'}   = $plan_name
        if defined $plan_name;
    $subscription_form{'metadata[campaign]'}    = $campaign
        if defined $campaign;
    $subscription_form{'metadata[appeal_code]'} = $appeal_code
        if defined $appeal_code;

    my $sub_res = $ua->post(
        'https://api.stripe.com/v1/subscriptions' => {
            Authorization => "Bearer $stripe_secret"
        } => form => \%subscription_form
    )->res;

    if ( !$sub_res->code || $sub_res->code !~ /^2/ ) {
        $self->app->log->error(
            "Stripe subscription error ["
                . ( $sub_res->code // 'no-code' )
                . "]: "
                . $sub_res->body );
        $self->flash(
            {   error =>
                'We could not start your subscription. Please try again.'
            }
        );
        $self->redirect_to('/');
        return;
    }

    my $sub = $sub_res->json;

    my $trans_date = '';
    if ( defined $sub->{created} ) {
        my $dt = DateTime->from_epoch( epoch => $sub->{created} );
        $dt->set_time_zone('Europe/London');
        $trans_date = $dt->ymd . ' ' . $dt->hms;
    }

    my $transaction_details = {
        email              => $email,
        first_name         => $first_name,
        last_name          => $last_name,
        hosted_login_token => '',
        trans_date         => $trans_date,
        address1           => $address,
        city               => $city,
        state              => $state,
        country            => $country,
        zip                => $postal,
        amount_in_cents    => $amount_in_cents,
        plan_name          => $plan_name,
        plan_code          => $plan_code,
        campaign           => $campaign,
        (
            defined $raiser
                ? ( 'raiser' => $self->raiser_decode($raiser) )
                : ()
        ),
        appeal_code            => $appeal_code,
        referrer               => $referrer,
        payment_type           => 'recurring',
        phone                  => $phone,
        user_agent             => $self->req->headers->user_agent,
        stripe_customer_id     => $stripe_customer_id,
        stripe_subscription_id => $sub->{id},
        stripe_interval        => $interval,
    };

    my $noxml = '<?xml version="1.0" ?>'
        . "\n"
        . '<metadata>'
        . "\n"
        . '</metadata>';
    my $xml_converter = XML::Hash->new();
    my $xml_hash      = $xml_converter->fromXMLStringtoHash($noxml);

    my $result = $self->find_or_new(
        $transaction_details,
        $xml_hash,
        "STRIPE_SUBSCRIPTION",
        $params,
        $original_params
    );
    $transaction_details->{'id'} = $result->id;
    $self->flash( { transaction_details => $transaction_details } );

    if ( $self->stash('iframe') | $self->flash('iframe') ) {
        $self->stash( 'iframe' => 1 );
        $self->flash( 'iframe' => 1 );
    }

    $self->redirect_to('/perks');
};

any [qw(GET POST)] => '/perks' => sub {
    my $self   = shift;
    my $record = $self->flash('transaction_details');
    $self->stash( { record => $record, } );
    $self->flash( { transaction_details => $record } );

    if ( $self->req->method eq 'POST' && $record ) {
        my $noxml = '<?xml version="1.0" ?>'
            . "\n"
            . '<metadata>'
            . "\n"
            . '</metadata>';
        my $xml_converter = XML::Hash->new();
        my $xml_hash      = $xml_converter->fromXMLStringtoHash($noxml);
        my $params        = $self->req->body_params->to_hash;
        my $original_params = $self->flash('original_params');
        my $update = $self->find_or_new(
            $record,
            $xml_hash,
            "PERKS_PHASE",
            $params,
            $original_params
        );
        $update->update( $self->req->params->to_hash );
        $record->{'pref_lapel'} = $update->pref_lapel;
        $self->flash( { transaction_details => $record } );
        if ( $self->stash('iframe') | $self->flash('iframe') ) {
            $self->stash( 'iframe' => 1 );
            $self->flash( 'iframe' => 1 );
        }
        $self->redirect_to('preferences');
    }
} => 'perks';

any [qw(GET POST)] => '/preferences' => sub {
    my $self   = shift;
    my $record = $self->flash('transaction_details');
    $self->stash( { record => $record, } );
    $self->flash( { transaction_details => $record } );

    if ( $self->req->method eq 'POST' && $record ) {
        my $validation = $self->validation;
        $validation->required('pref_frequency');
        $validation->required('pref_anonymous');

        $self->app->log->info( Dumper $validation )
            if $validation->has_error;
        $self->app->log->info( Dumper $self->req->params->to_hash )
            if $validation->has_error;

        my $noxml = '<?xml version="1.0" ?>'
            . "\n"
            . '<metadata>'
            . "\n"
            . '</metadata>';
        my $xml_converter = XML::Hash->new();
        my $xml_hash      = $xml_converter->fromXMLStringtoHash($noxml);
        my $params        = $self->req->body_params->to_hash;
        my $original_params = $self->flash('original_params');
        my $update = $self->find_or_new(
            $record,
            $xml_hash,
            "PREFERENCES_PHASE",
            $params,
            $original_params
        );

        $update->update( $self->req->params->to_hash );
        $record->{'on_behalf_of'} = $update->on_behalf_of;
        $self->flash( { transaction_details => $record } );

        if ( $self->stash('iframe') | $self->flash('iframe') ) {
            $self->stash( 'iframe' => 1 );
            $self->flash( 'iframe' => 1 );
        }

        $self->redirect_to('share');
    }
} => 'preferences';

get '/share' => sub {
    my $self                = shift;
    my $transaction_details = $self->flash('transaction_details');
    my $email               = $transaction_details->{'email'};
    $self->app->log->info( Dumper $transaction_details );
    $self->stash(
        {   transaction_details => $transaction_details,
            raiser_id           => $self->raiser_encode($email),

        }
    );
    $self->render('share');
} => 'share';

any [qw(GET POST)] => '/help-us-grow' => sub {
    my $self  = shift;
    my $email = $self->param('email');
    $self->stash(
        {   (   defined $email
            ? ( 'raiser_id' => $self->raiser_encode($email) )
            : ( 'raiser_id' => '' )
        ),

        }
    );
    $self->render('raiser');
} => 'raiser';

get '/leaderboard' => sub {
    my $self = shift;
    my $rs   = $self->search_records(
        'Transaction',
        { raiser => { '!=', undef }, }
    );

    my $raisers = {};
    while ( my $raised = $rs->next ) {
        $raisers->{ $raised->raiser }->{'count'}++;
    }
    for my $raiser ( keys %$raisers ) {
        my $raisers_rs
            = $self->search_records( 'Transaction', { email => $raiser } );
        my $r = $rs->first;
        if ($r) {
            $raisers->{$raiser}->{'first_name'} = $r->first_name;
            $raisers->{$raiser}->{'last_name'}  = $r->last_name;
            $raisers->{$raiser}->{'anonymous'}  = $r->pref_anonymous;
        }
    }
    my @keys    = sort { $raisers->{$a} cmp $raisers->{$b} } keys(%$raisers);
    my @vals    = @{$raisers}{@keys};
    my @ordered = sort { $b->{'count'} <=> $a->{'count'} } @vals;
    $self->stash( leaders => \@ordered );
    $self->render('leaderboard');
} => 'leaderboard';

get '/plans' => sub {    # List plans; Not used
    my $self = shift;
    $self->render_not_found;    # Doesn't exist for now
    my $res = $ua->get( $API . 'plans' => { Accept => 'application/xml' } )->res;
    my $xml   = $res->body;
    my $dom   = Mojo::DOM->new($xml);
    my @plans = $dom->find('plan');
    $self->stash( { plans => @plans } );
    $self->render('index');
};

app->secret( $config->{'app_secret'} );
app->log( Mojo::Log->new( path => 'support.app.log', level => 'debug' ) );
app->start;

__DATA__

@@ default.html.ep
% layout 'default';
<div style="width: 100%; height: 500px; text-align:center;">
<p>
<%=$content%>
</p>
</div>
