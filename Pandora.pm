package Plugins::Pyrrha::Pandora;

use strict;

use Exporter 'import';
our @EXPORT_OK = qw(getWebService getStationList getPlaylist getStationArtUrl getAdMetadata registerAd);

use Slim::Utils::Prefs;
use Slim::Networking::Async::HTTP;
use Digest::MD5 qw(md5_hex);
use JSON;
use WebService::Pandora;
use WebService::Pandora::Partner::AIR;
use WebService::Pandora::Partner::iOS;
use Promise::ES6;
use Plugins::Pyrrha::Utils qw(fetch);
use Plugins::Pyrrha::Skips;

my $log = Slim::Utils::Log->addLogCategory({
  category     => 'plugin.pyrrha',
  defaultLevel => 'INFO',
  description  => 'PLUGIN_PYRRHA_MODULE_NAME',
});

my $prefs = preferences( 'plugin.pyrrha' );


my %cache = ();
my $json = JSON->new->utf8;


my $WEBSVC_LIFETIME = (60 * 60 * 4) - (60 * 2);  # 4 hrs - 2 min grace
my $STATIONLIST_PAGESIZE = 250;                  # How many stations to retrieve at a time
my $STATIONART_SIZE = 500;                       # Size of station art to use. 90, 130, 500, 640, 1080


my $expiredCacheItem = Promise::ES6->resolve({expiresAt => 0});
sub _getCachedPerishable {
  my (%args) = @_;
  my $key      = $args{'key'};
  my $refresh  = $args{'refresh'};
  my $lifetime = $args{'lifetime'};

  # by default, the perishable is expired
  $cache{$key} = $expiredCacheItem if ! $cache{$key};

  # get the current cached object
  my $cacheItem = $cache{$key};
  $cacheItem->then(sub {
  my $oldPerishable = shift;

  # use it if not expired
  return $oldPerishable->{'object'} if time() < $oldPerishable->{'expiresAt'};

  # restart if we raced another request for this key
  return _getCachedPerishable(%args) if $cacheItem != $cache{$key};

  # otherwise create a new one
  my $newPerishable = $refresh->($oldPerishable->{'object'})->then(sub {
      return {
        'expiresAt' => time() + $lifetime,
        'object' => shift,
      };
    });

  # cache it
  $cache{$key} = $newPerishable;

  # if it fails, expire it so we retry next time
  $newPerishable->catch( sub {
      $cache{$key} = $expiredCacheItem;
    });

  return $newPerishable->then(sub { shift->{'object'} });

  });
}


sub getWebService {
  _getCachedPerishable(
    key => 'webService',
    lifetime => $WEBSVC_LIFETIME,
    refresh => sub {
      $log->info('creating new websvc');
      return _getWebService();
    }
  );
}


my @_partners = (
  WebService::Pandora::Partner::AIR->new(),
  WebService::Pandora::Partner::iOS->new(),
);
my %_useAltPartner = ();
sub _getWebService {
  my $attempts = shift || 0;
  my $username = $prefs->get('username');
  my $password = $prefs->get('password');
  my $partner  = $_useAltPartner{$username} || 0;

  my $websvc = WebService::Pandora->new(
    username => $username,
    password => $password,
    partner  => $_partners[$partner],
  );
  $websvc->login()->then(sub {
  my $user = shift;

  my $idealPartner = $user->{'isSubscriber'} ? 0 : 1;

  # check to see if we're using the best partner
  if (   $partner != $idealPartner
      && $attempts < 1) {
    $log->info('switching to alt partner');
    $_useAltPartner{$username} = $idealPartner;
    return _getWebService(1);
  }

  # save some user info
  $websvc->{'_userConfig'} = {
      'hasAudioAds'            => $user->{'hasAudioAds'},
      'maxStationsAllowed'     => $user->{'maxStationsAllowed'},
      'isSubscriber'           => $user->{'isSubscriber'},
      'stationHourlySkipLimit' => $user->{'stationHourlySkipLimit'},
      'dailySkipLimit'         => $user->{'dailySkipLimit'},
    };

  # set this user's skip allowance
  $log->info(
        'skip allowance: '
      . $websvc->{'_userConfig'}->{'stationHourlySkipLimit'}
      . ' / '
      . $websvc->{'_userConfig'}->{'dailySkipLimit'}
    );
  Plugins::Pyrrha::Skips::setSkipAllowance(
      md5_hex($username),
      $websvc->{'_userConfig'}->{'stationHourlySkipLimit'},
      $websvc->{'_userConfig'}->{'dailySkipLimit'},
    );

  return $websvc;

  })->catch(sub {
  my $error = shift;

  $error = $error->{'message'} if ref $error eq 'HASH';
  die $error

  });
}


sub getStationList {
  _getCachedPerishable(
    key => 'stationList',
    lifetime => 10,  # rate limit a litte bit
    refresh => sub {
      $log->info('fetching station list');
      return _getStationList(@_);
    }
  )->then(sub {
    my $stationList = shift;
    return $stationList->{'stations'};
  });
}


sub _getStationList {
  # the perishable cache will provide the expired data, if any.
  my $previous = shift;

  # get a websvc
#  getWebService()->then(sub{
#  my $websvc = shift;

  # now get the station list checksum
#  $websvc->getStationListChecksum();
#  })->then(sub {
#  my $checksum = shift->{'checksum'};
  my $checksum;

  # use the previous list if the checksum has not changed
#  return $previous if $previous && $checksum eq $previous->{'checksum'};

  # otherwise, fetch a new list
  return Promise::ES6->all([

    # get the quickmix/shuffle station, if configured
    ($prefs->get('disableQuickMix')
       ? Promise::ES6->resolve(0)
       : _invokeRestApi('v1/station/shuffle')
    )->catch(sub {
      # api call will fail if the station list is empty; just swallow it
      $log->debug('unable to get shuffle station');
      return 0;
    }),

    # fetch the user's stations
    _getStationListPages(),

  ])->then(sub {
  my $results = shift;
  my ($quickmix, $stations) = @$results;

  # add quickmix to the user's station list
  unshift @$stations, $quickmix if $quickmix;

  return {
      stations => $stations,
      checksum => $checksum,
    };
  });
#  });
}


sub _getStationListPages {
  my $stations = shift || [];

  # fetch the next page of stations
  _invokeRestApi(
    'v1/station/getStations',
    pageSize   => $STATIONLIST_PAGESIZE,
    startIndex => scalar @$stations,
  )->then(sub {
  my $result = shift;
  my $page = $result->{'stations'};
  my $totalStations = $result->{'totalStations'};

  # add this page of stations to the list
  push @$stations, @$page;

  # fetch more if needed
  if (scalar @$stations < $totalStations) {
    return _getStationListPages($stations);
  }
  # otherwise, return the list
  else {
    return $stations;
  }

  });
}


sub getStationArtUrl {
  my $station = shift;
  return unless (
    $station &&
    ref $station eq 'HASH' &&
    ref $station->{'art'} eq 'ARRAY'
  );
  for my $art (@{$station->{'art'}}) {
    return $art->{'url'} if $art->{'size'} == $STATIONART_SIZE;
  }
  $log->debug("No station art matching size ${STATIONART_SIZE} found");
  return $station->{'art'}->[0]->{'url'};
}


sub getPlaylist {
  my $stationId = shift;

  # first, get a websvc
  getWebService()->then(sub{
  my $websvc = shift;

  # now fetch a play list
  $websvc->getPlaylist(stationToken => $stationId);
  })->then(sub {
  my $result = shift;

  return $result->{'items'};

  # manage any errors
  })->catch(sub {
  my $error = shift;

  if (ref $error eq 'HASH') {
    if ($error->{'apiCode'} == 1001) {
      # auth token expired, clear our cached credentials
      $log->info('auth token expired, clearing cache');
      %cache = ();
    }
    $error = $error->{'message'}
  }

  die $error;

  });
}


sub getAdMetadata {
  my (%args) = @_;
  # adToken

  getWebService()->then(sub {
  my $websvc = shift;

  return $websvc->getAdMetadata(%args);

  })->catch(sub {
  my $error = shift;
  $error = $error->{'message'} if ref $error eq 'HASH';
  die $error;
  });
}


sub registerAd {
  my (%args) = @_;
  # stationId
  # adTrackingTokens

  getWebService()->then(sub {
  my $websvc = shift;

  return $websvc->registerAd(%args);

  })->catch(sub {
  my $error = shift;
  $error = $error->{'message'} if ref $error eq 'HASH';
  die $error;
  });
}


# we can issue multiple rest api requests in parallel, so we need to
# "cache" the csrf token request otherwise the cookie can change while
# we're preparing the api request
sub _getCSRFToken {
  _getCachedPerishable(
    key => 'csrftoken',
    lifetime => $WEBSVC_LIFETIME,
    refresh => sub {
      fetch('https://www.pandora.com', method => 'HEAD')
      ->catch(sub {
        my $e = shift;
        die $e->{'error'};
      });
    }
  )
  # always read from the cookie jar in case the service pushed a new
  # cookie value as part of an api request response
  ->then(sub {
    my $csrftoken = Slim::Networking::Async::HTTP->cookie_jar->
      get_cookies('.pandora.com', 'csrftoken');
    die 'failed to obtain CSRF token' unless $csrftoken;
    return $csrftoken;
  });
}


sub _invokeRestApi {
  my ($endpoint, %args) = @_;

  Promise::ES6->all([

  # get the CSRF token
  _getCSRFToken(),

  # get our webservice
  getWebService(),

  ])->then(sub {
  my $results = shift;
  my ($csrftoken, $websvc) = @$results;

  # invoke the rest api
  fetch("https://www.pandora.com/api/${endpoint}",
    method => 'POST',
    headers => {
      'X-CsrfToken' => $csrftoken,
      'X-AuthToken' => $websvc->{'userAuthToken'},
      'Content-Type' => 'application/json;charset=utf-8',
    },
    body => $json->encode(\%args),
  )->catch(sub {
    my $e = shift;
    die $e->{'error'};
  });

  })->then(sub {
  my $response = shift;

  # decode the response
  return $json->decode($response->content);

  });
}


1;
