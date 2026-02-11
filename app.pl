#!/usr/bin/env perl


use FindBin;
use lib "$FindBin::Bin/local/lib/perl5";

use Mojolicious::Lite;
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

helper schema => sub {
    my $schema = Support::Schema->connect( $config->{'pg_dsn'},
        $config->{'pg_user'}, $config->{'pg_pass'}, );
    return $schema;
};

helper find_or_new => sub {
    my $self = shift;
    my $doc  = shift;
    my $dom = shift;
    my $trans_type = shift;
    my $params = shift;
    my $original_params = shift;
    my $dbh  = $self->schema();
    my $result;

    #DSL
    $self->app->log->debug("FIND_OR_NEW");
    $self->app->log->debug( Dumper $doc );
    
    try {
        $result = $dbh->txn_do(
            sub {
                my $rs = $dbh->resultset( 'Transaction' )
                    ->find_or_new( {%$doc} );
                unless ( $rs->in_storage ) {
                    $rs->insert;
                }
                return $rs;
            }
        );
    }
    catch {
        $self->app->log->warn( $_ );
    };

    #DSL
    $self->app->log->debug("FIND_OR_NEW AFTER txn_do");

    $self->app->log->debug($doc);
    
    my $hashref = {};
    
    $doc->{'id'} = $result->id;
    if ($doc) {
    $hashref-> {"local"} = $doc;
    }
    if ($dom && $trans_type) {
    $hashref->{$trans_type} = $dom;
    }
    if ($params) {
     $hashref->{'params'}  = $params;
    }
    if ($original_params) {
     $hashref->{'original_params'} = $original_params;
    }
         $self->app->log->info("dump of hashref");

     $self->app->log->info( Dumper($hashref));
             $self->app->log->info("end dump of hashref");

    
    my $drupal_endpoint = $config->{'drupal_endpoint'};

    #DSL
    $self->app->log->debug("DRUPAL ENDPOINT");
    $self->app->log->debug($drupal_endpoint);

      my $res = $ua->post( $config->{'drupal_endpoint'} => {  Accept => '*/*' } => json => $hashref);
        $self->app->log->info("return from drupal dump:");
        $self->app->log->info( Dumper($res));
        $self->app->log->info("end drupal dump:");
                $self->app->log->info( "result dump");

        $self->app->log->info( Dumper($result));
                        $self->app->log->info( "end result dump");


        
    return $result;
};

helper search_records => sub {
    my $self      = shift;
    my $resultset = shift;
    my $search    = shift;
    my $schema    = $self->schema;
    my $rs        = $schema->resultset( $resultset )->search( $search );
    return $rs;
};

helper recurly_get_plans => sub {
    my $self   = shift;
    my $filter = shift;
    my $res = $ua->get( $API . '/plans?per_page=200' => { Accept => 'application/xml' } )->res;
    my $xml      = $res->body;
    my $dom      = Mojo::DOM->new( $xml );
    my $plans    = $dom->find( 'plan' );

    #  app->log->debug("Plans " . Dumper $xml);



    my $filtered = [];
    foreach my $plan ( $plans->each ) {    # iterate the Collection object
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
    my $res
        = $ua->get( $API
            . '/accounts/'
            . $account_code => { Accept => 'application/xml' } )->res;
    my $xml = $res->body;
    my $dom = Mojo::DOM->new( $xml );
    return $dom;
};

helper recurly_get_billing_details => sub {
    my $self         = shift;
    my $account_code = shift;
    my $res
        = $ua->get( $API
            . '/accounts/'
            . $account_code
            . '/billing_info' => { Accept => 'application/xml' } )->res;
    my $xml = $res->body;
    my $dom = Mojo::DOM->new( $xml );
    return $dom;
};

helper recurly_get_active_subs => sub {
    my $self         = shift;
    my $account_code = shift;
    my $res
        = $ua->get( $API
            . '/accounts/'
            . $account_code
            . '/subscriptions?state=active' => { Accept => 'application/xml' } )->res;
    my $xml = $res->body;
    my $dom = Mojo::DOM->new( $xml );
       my $ub = Mojo::UserAgent->new;
my $collection = $dom->find('subscription');
my @elements = $collection->each;
#DSL
$self->app->log->debug(@elements);
if ((scalar @elements) >= 2 ) {
 $ub->post($config->{'notify_url'} => json => {text => "Note: Count of subs for someone who just subscribed, account code $account_code are greater than 1, they are " . (scalar @elements) });
}
    return $dom;
 
};

# Set the salt and initialize the cipher
my $salt = $config->{'app_secret'};
my $cipher = Crypt::CBC->new( $salt, 'Blowfish' );

helper raiser_encode => sub {
    my $self           = shift;
    my $email          = shift;
    my $encrypted_data = $cipher->encrypt( $email );
    my $safe_data      = urlsafe_b64encode( $encrypted_data );
    return $safe_data;
};

helper raiser_decode => sub {
    my $self           = shift;
    my $safe_data      = shift;
    my $encrypted_data = urlsafe_b64decode( $safe_data );
    my $decrypted_data = $cipher->decrypt( $encrypted_data );
    return $decrypted_data;
};



group {
    under [ qw(GET POST) ] => '/' => sub {
        my $self = shift;


        # Store the referrer once in the flash
        my $referrer = $self->req->headers->referrer;
        if (!$self->flash('original_referrer')) {
            $self->flash(original_referrer => $referrer);
        }

        # Store the campaign-tracking value
        my $campaign
            = $self->param('campaign') || $self->flash('campaign');
        $self->flash(campaign => $campaign);
        my $raiser = $self->param('raiser') || $self->flash('raiser');
        $self->flash(raiser => $raiser);

        # TODO remove these two
        my $onetime = $self->param('onetime');
        my $amount = $self->param('amount');

        # TODO remove this statement
        if ($self->req->method eq 'POST' && $amount =~ /\D/) {
            $self->flash(
                { error      => 'Amount needs to be a whole number',
                    onetime  => 'onetime',
                    campaign => $campaign,
                }
            );
            $self->param({ amount => '0' });
            $amount = '';
            $self->redirect_to('');
        }

        # TODO remove
        my $amount_in_cents;
        if ($amount) {
            $amount_in_cents = $amount * 100;
        }

        # TODO remove this hash
        my $options = { # RecurlyJS signature options
            'transaction[currency]'        => 'CAD',
            'transaction[amount_in_cents]' => $amount_in_cents,
            'transaction[description]'     =>
                'Support for fact-based independent journalism at The Tyee',
        };

        my $plans = $self->recurly_get_plans(
            $config->{'recurly_get_plans_filter'});
        my $annual_plans = $self->recurly_get_plans(
            $config->{'recurly_annual_plans_filter'});
        $self->stash(
            { plans           => $plans,
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

    any [ qw(GET POST) ] => '/' => sub {
        my $ab;
        my $self = shift;
        #        my $dt          = DateTime->now;
        #        my $seconds =  $dt->sec;
        my $display;
        my $urlstring;
        my $count;


        #             my $params = $self->req->query_params;
        #                 app->log->debug(  "url string  = $params");
        # my $path = "/b" . '?' . $params;
        #      if ($seconds >= 29) {
        #       $self->redirect_to( $path);
        #     } else {
        #    $ab = 'evergreen-squeeze'; # $display = "none";
        #   }
        $ab = 'evergreen-squeeze'; # $display = "none";

        $self->stash(body_id => $ab,);
        $self->flash(appeal_code => $ab);
        $self->stash(display => $display);
        $self->flash(original_params => $self->req->query_params);
    }                    => 'evergreen-squeeze';

    # making both of these test conditions Dec2021 so can easily ad a test if we want during campaign.  Probably a waste of resources if not using later
    any [ qw(GET POST) ] => '/Spring2024' => sub {
        my $ab = 'Spring2024';
        my $self = shift;
        #        my $dt          = DateTime->now;
        #       my $seconds =  $dt->sec;
        my $display;


        #      if ($seconds >= 29) {
        #       $self->redirect_to( 'b' );
        #     } else {
        #    $ab = 'Spring2024'; # $display = "none";
        # if ($self->param( 'squeeze' ) ) {$ab = $self->param( 'evergreen-squeeze' ) ; $display = "none"; };
        #  if ($self->param( 'evergreen' ) ) {$ab = $self->param( 'evergreen' ) ; $display = "block"; };
        $self->stash(body_id => $ab,);
        $self->flash(appeal_code => $ab);
        $self->stash(display => $display);
    }                    => 'Spring2024';

    any [ qw(GET POST) ] => '/b' => sub {
        my $ab;
        my $self = shift;
        my $dt = DateTime->now;
        my $seconds = $dt->sec;
        my $display;
        $ab = 'evergreen-squeeze';
        if ($self->param('squeeze')) {
            $ab = $self->param('evergreen-squeeze');
            $display = "none";
        };
        if ($self->param('evergreen')) {
            $ab = $self->param('evergreen');
            $display = "block";
        };
        #  $display = "block";  #undoing all the above
        $self->stash(body_id => $ab,);
        $self->flash(appeal_code => $ab);
        $self->stash(display => $display);
    }                    => 'evergreen-squeeze';

    any [ qw(GET POST) ] => '/powermap' => sub {
        my $self = shift;
        $self->stash(
            body_id     => 'powermap',
            appeal_code => 'powermap'
        );
    }                    => 'powermap';

    any [ qw(GET POST) ] => '/iframe' => sub {
        my $self = shift;
        $self->stash(
            body_id     => 'iframe',
            appeal_code => 'iframe'
        );
    }                    => 'iframe';

    any [ qw(GET POST) ] => '/Spring2023' => sub {
        my $self = shift;
        $self->stash(
            body_id     => 'Spring2023',
            appeal_code => 'Spring2023'
        );
    }                    => 'Spring2023';

    any [ qw(GET POST) ] => 'rafemair' => sub {
        my $self = shift;
        $self->stash(
            body_id     => 'RafeMair2017',
            appeal_code => 'RafeMair2017'
        );
        $self->flash(appeal_code => 'RafeMair2017');
    }                    => 'RafeMair';

    any [ qw(GET POST) ] => '/builders' => sub {
        my $self = shift;
        $self->stash(
            body_id     => 'builders',
            appeal_code => 'builders'
        );
    }                    => 'builders';

    any [ qw(GET POST) ] => '/builders' => sub {
        my $self = shift;
        $self->stash(
            body_id     => 'builders',
            appeal_code => 'builders'
        );
    }                    => 'builders';

    any [ qw(GET POST) ] => '/dec2018' => sub {
        my $self = shift;
        $self->stash(
            body_id     => 'dec2018',
            appeal_code => 'dec2018'
        );
    }                    => 'DecBuilderCamp2019';

    any [ qw(GET POST) ] => '/national' => sub {
        my $self = shift;
        $self->stash(
            body_id     => 'national',
            appeal_code => 'national'
        );
    }                    => 'national';
    any [ qw(GET POST) ] => '/evergreen' => sub {
        my $self = shift;
        $self->stash(
            body_id     => 'evergreen',
            appeal_code => 'evergreen',
            display     => 'block'
        );
    }                    => 'evergreen';

    any [ qw(GET POST) ] => '/evergreen-squeeze' => sub {
        my $self = shift;
        $self->stash(
            body_id     => 'evergreen-squeeze',
            appeal_code => 'evergreen-squeeze',
            display     => 'block'
        );
    }                    => 'evergreen-squeeze';
    any [ qw(GET POST) ] => '/election2017-2' => sub {
        my $self = shift;
        $self->stash(
            body_id     => 'election2017-2',
            appeal_code => 'election2017-2'
        );
        $self->flash(appeal_code => 'election2017-2');
    }                    => 'election2017-2';

    any [ qw(GET POST) ] => '/election2015' => sub {
        my $self = shift;
        $self->stash(
            body_id     => 'election2015',
            appeal_code => 'election2015'
        );
        $self->flash(appeal_code => 'election2015');
    }                    => 'election2015';
    any [ qw(GET POST) ] => '/voices' => sub {
        my $self = shift;
        $self->stash(
            body_id     => 'voices',
            appeal_code => 'voices'
        );
        $self->flash(appeal_code => 'voices');
    }                    => 'voices';
};

# New route for processing EFT/ACH subscriptions
any [qw(GET POST)] => '/process_bank' => sub {
    my $self        = shift;
    my $params      = $self->flash( 'params' );
    my $campaign    = $self->flash( 'campaign' );
    my $appeal_code = $self->flash( 'appeal_code' );
    my $referrer    = $self->flash( 'original_referrer' );
    my $raiser      = $self->flash( 'raiser' );
    my $dt          = DateTime->now;
    $dt->set_time_zone( 'Europe/London' );
    my $trans_date = $dt->ymd . ' ' . $dt->hms;
    my $states     = $params->{'state'};
    my $original_params =    $self->flash( 'original_params' );

    # There are two possible state values, but only one should be used
#    my $state = @$states[0] ? @$states[0] : @$states[1];

my $state;

if ( ref($states) && @$states) {

 if (@$states[0] ) {$state = @$states[0]
} elsif (@$states[1]) {$state = @$states[1]
} elsif ($params->{'state'}) { $state = $params->{'state'} }

} else {
$state = $params->{'state'} ;
}

    my $transaction_details = {
        email              => $params->{'email'},
        phone              => $params->{'phone'},
        first_name         => $params->{'first-name'},
        last_name          => $params->{'last-name'},
        hosted_login_token => 'Bank transaction. Not applicable',
        trans_date         => $trans_date,                        # Add a date
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
            ? ( 'raiser' => $self->raiser_decode( $raiser ) )
            : ()
        ),
        appeal_code => $appeal_code,
        referrer    => $referrer,
        user_agent  => $self->req->headers->user_agent,
    };
    
      my $res = $ua->post( $config->{'iats_process_proxy'} => {  Accept => '*/*' } => form => $transaction_details);
app->log->debug( "res->body from iats proxy dump:");

app->log->debug( Dumper($res->res->content->asset->{"content"}));
   app->log->debug( "end res->body from iats proxy dump:");
    
      my $json_return = decode_json($res->res->content->asset->{"content"});
      
      
      
    my $result = $self->find_or_new( $transaction_details, $json_return, "IATS", $params, $original_params);
    $transaction_details->{'id'} = $result->id;
    $self->flash( { transaction_details => $transaction_details, } );
    
    
  
 #    app->log->debug(  Dumper $res);

  
    $self->redirect_to( 'perks' );
};


post '/get_update_link' => sub {
        my $self = shift;
    my $email;
    my $res;
    my $text;

                $email = {    
            'account' => {
                'account_code' => $self->param( 'email' )
                }
            };

        # Post the XML to the /transacdtions endpoint
        $res = $ua->get( $API. 'accounts/' .$self->param( 'email' ) =>  { 'Content-Type' => 'application/xml', Accept => '*/*' });
        
             
 
      
      
     #   app->log->debug( "email is " . $self->param( 'email' ) . Dumper $res);
     my $xml = $res->res->content->asset->{content};
# $text .= dumper_html($res);
      
      
   my $dom = Mojo::DOM->new( $xml );
   if ( $dom->at( 'error' ) ) {    # We got an error message back
        my $error = $dom->at( 'error' )->text;
        $self->flash( { error => $error } );
        $text .=  "Your email address was not found in our system. Please send an email to builders AT thetyee DOT ca or give us a call to update your account." ;
    }
   else {    # Otherwise, store the transaction and send to /preferences
        
    if ($dom->at( 'hosted_login_token' )->text && $dom->at( 'hosted_login_token' )->text ne '') {
    #$text .= "hosted_login_token" .  'https://thetyee.recurly.com/account/' . $dom->at( 'hosted_login_token' )->text;
     $text .= "You have been sent an email with a link to update your account with us.";
   
    
  
   $self->mail(
    from => 'builders@thetyee.ca',
    type => 'text/html',
    to      => $self->param( 'email' ),
    bcc     => 'builders@thetyee.ca',
    subject => 'The Tyee - Modify Your Builder Account',
    data    => 'You appear to have requested your sign-in for your builder account with The Tyee at https://support.thetyee.ca.  You can sign in to your account by visiting the following link: https://' . $subdomain .'.recurly.com/account/' .  $dom->at( 'hosted_login_token' )->text . "\n \n <br><br>"  . 'Note that for security reasons, if you are updating a card you have to re-input the entire card, expiry and security code (even if only the expiry has changed). If this was sent by mistake you can delete or ignore it - we only send this information to the email registered on the account.',
  );
   
    } else {
        
    }
   
   
    }
    
    $self->render(template => 'default',  content => $text, title => "The Tyee | Get account management link",  body_id => '');
    # $self->render(text => $text);
    
    
};
    

# New route for processing the form post with the upgraded Recurly.js
# Take the token, plus the plan, and send a post to the Recurly Subscrptions API
# post '/process_transaction
post '/process_transaction' => sub {
    my $self = shift;

    #DSL
    $self->app->log->debug("Hit /process_transaction");

    # Capture values from flash
    my $campaign     = $self->flash( 'campaign' );
    my $appeal_code  = $self->flash( 'appeal_code' );
    my $referrer     = $self->flash( 'original_referrer' );
    my $raiser       = $self->flash( 'raiser' );
    my $payment_type = $self->param( 'payment-type' );
    my $token        = $self->param( 'recurly-token' );
    my $plan_name    = $self->param( 'plan-name' );
    my $plan_code    = $self->param( 'plan-code' );

    # TODO remove $amount
    my $amount          = $self->param( 'amount' );
    my $amount_in_cents = $self->param( 'amount-in-cents' );
    my $unit_amount_in_cents = $self->param( 'unit-amount-in-cents' );
    my $first_name      = $self->param( 'first-name' );
    my $last_name       = $self->param( 'last-name' );
    my $address         = $self->param( 'address1' );
    my $city            = $self->param( 'city' );
    my $state           = $self->param( 'state' );
    my $country         = $self->param( 'country' );
    my $postal          = $self->param( 'postal-code' );
    my $email           = $self->param( 'email' );
    my $phone           = $self->param( 'phone' );
    my $params          = $self->req->body_params->to_hash;
    my $original_params = $self->flash('original_params');

    if ( $payment_type eq 'bank' )
    {    # If it's a EFT/ACH, redirect to /process_bank
        $self->flash(
            {   params            => $params,
                campaign          => $campaign,
                raiser            => $raiser,
                appeal_code       => $appeal_code,
                original_referrer => $referrer,
                original_params => $original_params
            }
        );
        $self->redirect_to( 'process_bank' );
        return;
    }

    # Create a new XML document to work with Recurly's APIs
    my $xmldoc = XML::Mini::Document->new();

    # This can be done using a hash:
    my $transaction;
    my $res;
    if ( !$plan_code && $amount_in_cents )
    {    # It's a transaction, not a subscription
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
        $xmldoc->fromHash( $transaction );
        my $transxml = $xmldoc->toString;

        # Post the XML to the /transacdtions endpoint
        $res
            = $ua->post( $API
                . 'transactions' =>
                { 'Content-Type' => 'application/xml', Accept => '*/*' } =>
                $transxml )->res;
    }
    else {
        $transaction = {    # It's a subscription
            'subscription' => {
                'plan_code' => $plan_code,
                'currency'  => 'CAD',
                'unit_amount_in_cents' => $unit_amount_in_cents,
                'account'   => {
                    'account_code' => lc $email,
                    'first_name'   => $first_name,
                    'last_name'    => $last_name,
                    'email'        => lc $email,
                    'billing_info' => { 'token_id' => $token }
                }
            }
        };

        #DSL
        $self->app->log->debug("SUBSCRIPTION");
        $self->app->log->debug( Dumper $transaction );

        $xmldoc->fromHash( $transaction );
        my $transxml = $xmldoc->toString;

        # Post the XML to the /subscriptions endpoint
        $res
            = $ua->post( $API
                . 'subscriptions' =>
                { 'Content-Type' => 'application/xml', Accept => '*/*' } =>
                $transxml )->res;
    }
    my $xml = $res->body;
  
  
$self->app->log->info("dump of transaction or subscription:");    
$self->app->log->info( Dumper $xml );
$self->app->log->info("end of dump:");    

    my $dom = Mojo::DOM->new( $xml );
    if ( $dom->at( 'error' ) ) {    # We got an error message back
        my $error = $dom->at( 'error' )->text;
        $self->flash( { error => $error } );
        $self->redirect_to( '/' );
    }
    else {    # Otherwise, store the transaction and send to /preferences
        my $account_code = $self->recurly_get_account_code( $dom->at( 'account' ) );
        my $account = $self->recurly_get_account_details( $account_code );
        my $activesubs = $self->recurly_get_active_subs($account_code);
        my $billing_info = $self->recurly_get_billing_details( $account_code );
          
        my $transaction_details = {
            email      => $email,
            first_name => $first_name,
            last_name  => $last_name,

            # Recurly data
            hosted_login_token => $account->at( 'hosted_login_token' )
            ? $account->at( 'hosted_login_token' )->text
            : '',

            # Recurly data
            trans_date => $dom->at( 'created_at' )
            ? $dom->at( 'created_at' )->text
            : $dom->at( 'activated_at' ) ? $dom->at( 'activated_at' )->text
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
            (   defined $raiser
                ? ( 'raiser' => $self->raiser_decode( $raiser ) )
                : ()
            ),
            appeal_code  => $appeal_code,
            referrer     => $referrer,
            payment_type => $payment_type,
            phone        => $phone,
            user_agent   => $self->req->headers->user_agent,
        };
        my %domhash= %$dom;
        my $domref = \%domhash;
        $self->app->log->info( "domhash dump");
        $self->app->log->info( Dumper(%domhash));
        $self->app->log->info( "end domhash dump");

        my $xml_converter = XML::Hash->new();
        my $xml_hash = $xml_converter->fromXMLStringtoHash($xml);
            my $raiser      = $self->flash( 'raiser' );
        my $result = $self->find_or_new( $transaction_details, $xml_hash, "RECURLY", $params, $original_params);
        $transaction_details->{'id'} = $result->id;
        $self->flash( { transaction_details => $transaction_details } );
        $self->redirect_to( 'perks' );
    }
};

any [qw(GET POST)] => '/perks' => sub {
    my $self   = shift;
    my $record = $self->flash( 'transaction_details' );
    $self->stash( { record => $record, } );
    $self->flash( { transaction_details => $record } );

    if ( $self->req->method eq 'POST' && $record ) {
        my $v = $self->validation;

        # Helper to safely trim a param string
        my $trim = sub {
            my ($s) = @_;
            $s = '' unless defined $s;
            $s =~ s/^\s+//;
            $s =~ s/\s+$//;
            return $s;
        };

        # Read controlling fields (trimmed)
        my $pref_lapel = $trim->($v->optional('pref_lapel')->param);
        my $pref_tax   = $trim->($v->optional('pref_tax')->param);

        my $needs_address = ($pref_lapel eq 'Yes') || ($pref_tax eq 'Yes');

        if ($needs_address) {
            # Mark required on server
            $v->required('address1')->size(1, 255);
            $v->required('city')->size(1, 255);
            $v->required('zip')->size(1, 20);

            # Reject placeholder values for selects
            $v->required('state')->like(qr/^(?!\-\-|-)..+/);   # not "--" or "-"
            $v->required('country')->like(qr/^(?!-)..+/);      # not "-"

            # Extra guard: treat whitespace-only as empty (since no ->trim filter)
            for my $f (qw/address1 city zip/) {
                my $val = $trim->($v->param($f));
                $v->error($f => ['required']) if $val eq '';
            }
        } else {
            # Optional
            $v->optional('address1')->size(0, 255);
            $v->optional('city')->size(0, 255);
            $v->optional('zip')->size(0, 20);
            $v->optional('state');
            $v->optional('country');
        }

        if ($v->has_error) {
            $self->stash(record => $record);
            $self->flash({ transaction_details => $record });
            return $self->render(template => 'perks');
        }

my $noxml = '<?xml version="1.0" ?>' . "\n" . '<metadata>' . "\n" . '</metadata>';#creating blank xml so it will conform to expectations when received by the helper
 my $xml_converter = XML::Hash->new();
        my $xml_hash = $xml_converter->fromXMLStringtoHash($noxml);
         my $params          = $self->req->body_params->to_hash;
    my $original_params = $self->flash('original_params');
        my $update = $self->find_or_new( $record , $xml_hash, "PERKS_PHASE", $params, $original_params);
        $update->update( $self->req->params->to_hash );
        $record->{'pref_lapel'} = $update->pref_lapel;
        $self->flash( { transaction_details => $record } );
        $self->redirect_to( 'preferences' );
    }
} => 'perks';

any [qw(GET POST)] => '/preferences' => sub {
    my $self   = shift;
    my $record = $self->flash( 'transaction_details' );
    $self->stash( { record => $record, } );
    $self->flash( { transaction_details => $record } );

    if ( $self->req->method eq 'POST' && $record ) {    # Submitted form
            # TODO *actually* validate parameters with custom check
        my $validation = $self->validation;
        $validation->required( 'pref_frequency' );
        $validation->required( 'pref_anonymous' );

        # Render form again if validation failed
        # TODO actually render form again vs. just writing to log
        $self->app->log->info( Dumper $validation ) if $validation->has_error;
        $self->app->log->info( Dumper $self->req->params->to_hash )
            if $validation->has_error;

        #return $self->render( 'preferences' ) if $validation->has_error;
my $noxml = '<?xml version="1.0" ?>' . "\n" . '<metadata>' . "\n" . '</metadata>'; #creating blank xml so it will conform to expectations when received by the helper
 my $xml_converter = XML::Hash->new();
        my $xml_hash = $xml_converter->fromXMLStringtoHash($noxml);
         my $params          = $self->req->body_params->to_hash;
    my $original_params = $self->flash('original_params'); 
        my $update = $self->find_or_new( $record , $xml_hash, "PREFERENCES_PHASE", $params, $original_params);
       
        $update->update( $self->req->params->to_hash );
        $record->{'on_behalf_of'} = $update->on_behalf_of;
        $self->flash( { transaction_details => $record } );
        $self->redirect_to( 'share' );
    }
} => 'preferences';

get '/share' => sub {
    my $self                = shift;
    my $transaction_details = $self->flash( 'transaction_details' );
    my $email               = $transaction_details->{'email'};
    $self->app->log->info( Dumper $transaction_details );
    $self->stash(
        {   transaction_details => $transaction_details,
            raiser_id           => $self->raiser_encode( $email ),

        }
    );
    $self->render( 'share' );
} => 'share';

any [qw(GET POST)] => '/help-us-grow' => sub {
    my $self  = shift;
    my $email = $self->param( 'email' );
    $self->stash(
        {   (   defined $email
                ? ( 'raiser_id' => $self->raiser_encode( $email ) )
                : ( 'raiser_id' => '' )
            ),

        }
    );
    $self->render( 'raiser' );
} => 'raiser';

get '/leaderboard' => sub {
    my $self = shift;
    my $rs   = $self->search_records( 'Transaction',
        { raiser => { '!=', undef }, } );

    #my $count = $rs->count;
    #say Dumper( $count );
    my $raisers = {};
    while ( my $raised = $rs->next ) {
        $raisers->{ $raised->raiser }->{'count'}++;
    }
    # say Dumper( $raisers );
    for my $raiser ( keys %$raisers ) {
        my $raisers_rs
            = $self->search_records( 'Transaction', { email => $raiser } );
        my $r = $rs->first;
        if ( $r ) {
            $raisers->{$raiser}->{'first_name'} = $r->first_name;
            $raisers->{$raiser}->{'last_name'}  = $r->last_name;
            $raisers->{$raiser}->{'anonymous'}  = $r->pref_anonymous;
        }
    }
    #say Dumper( $raisers );
    my @keys = sort { $raisers->{$a} cmp $raisers->{$b} } keys( %$raisers );
    my @vals = @{$raisers}{@keys};
    my @ordered = sort { $b->{'count'} <=> $a->{'count'} } @vals;
    $self->stash( leaders => \@ordered );
    $self->render( 'leaderboard' );
} => 'leaderboard';

get '/plans' => sub {    # List plans; Not used
    my $self = shift;
    $self->render_not_found;    # Doesn't exist for now
    my $res
        = $ua->get( $API . 'plans' => { Accept => 'application/xml' } )->res;
    my $xml   = $res->body;
    my $dom   = Mojo::DOM->new( $xml );
    my @plans = $dom->find( 'plan' );
    $self->stash( { plans => @plans } );
    $self->render( 'index' );
};

app->secret( $config->{'app_secret'} );
#DSL
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
