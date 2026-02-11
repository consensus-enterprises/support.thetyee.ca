The amazing, awe-inspiring, crowd-funding platform for The Tyee
================================================================

# Install requirements

* A relatively "modern" version of Perl (5.20+ recommended)
* PostgreSQL

## Localdev installation with DDEV

There is a .ddev folder with config to spin this site up in a localdev
environment.  You will need to have [DDEV](https://ddev.com) and Docker
installed beforehand.

To do so, follow these steps:

### 1. Get the source / sub-modules

First, fork the repository so that you have your own copy. Then:

`git clone git@github.com:yourusername/support.thetyee.ca.git`

`git checkout develop` (Always work on the `develop` branch while developing!)

`git submodule init && git submodule update` (this installs the `public` files)

### 2. Get and edit the configuration files

Get them from the secret repository!

You'll need:

* app.development.json
* sqitch/sqitch.conf

You'll want to udpate the values in `app.development.json` and `sqitch/sqitch.conf` to point to your local PostgreSQL database.

### 3. Start DDEV

```
ddev start
```

This will spin up a web container with the required Perl packages installed, as
well as a database container running Postgres. The initial start will take a
few minutes as DDEV builds a custom container for the application, but
subsequent restarts will be faster.

**NB** This is likely to show an error starting the `app.pl` process, since we
don't have all the components in place yet. The next few steps happen inside
the container, so we'll reload the Perl application server once we finish the
next few steps.

### 4. Deploy database

These steps will deploy the database schemas into our database container.

```
ddev ssh
cd sqitch
sqitch deploy
exit
```

Output should be like this:

```
Deploying changes to db:pg://db:@db/db
  + schema ................. ok
  + transactions @v0.2.6 ... ok
  + transactions @v0.3.0 ... ok
  + transactions @v0.3.4 ... ok
  + transactions @v1.0.4 ... ok
  + transactions @v1.0.5 ... ok
  + transactions @v.1.0.6 .. ok
  + transactions @v1.0.7 ... ok
  + transactions @v1.7.0 ... ok
  + transactions @v1.7.2 ... ok
  + transactions ........... ok
```

### 5. Install the JavaScript dependencies

Install [Bower, the JavaScript package manager](http://bower.io/) and install
the project's JavaScript dependencies:

```
ddev ssh
cd public
npm install bower -g
bower install
exit
```

You should see output relating to Bootstrap, jQuery, and so on.

### 6. Reload the development server

This command will cause the Perl application server to reload the code in `app.pl` and related libraries:

```
ddev reload
```

From here, you should be able to hit https://support.ddev.site

## Installation

### 0. Install Perl & PostgreSQL (if you need them)

These days, I recommend using [plenv](https://github.com/tokuhirom/plenv) to install a local version of Perl that doesn't muck with your system perl binary.

To do that, just:

`git clone git://github.com/tokuhirom/plenv.git ~/.plenv`

`echo 'export PATH="$HOME/.plenv/bin:$PATH"' >> ~/.bash_profile`

`echo 'eval "$(plenv init -)"' >> ~/.bash_profile`

`exec $SHELL -l`

`git clone git://github.com/tokuhirom/Perl-Build.git ~/.plenv/plugins/perl-build/`

`plenv install 5.20.0`

For PostgreSQL, if you're on an Apple product, you'll probably want to use [homebrew](http://brew.sh/) or the fancy, new [Postgre app](http://postgresapp.com/).

Once you've got those working, move on!

### 1. Get the source / sub-modules

First, fork the repository so that you have your own copy. Then:

`git clone git@github.com:yourusername/support.thetyee.ca.git`

`git checkout develop` (Always work on the `develop` branch while developing!)

`git submodule init && git submodule update` (this installs the `public` files)

### 2. Install the JavaScript dependencies

If you don't have [NPM](https://www.npmjs.org/) installed, you'll need to do that first by installing [Node.js](http://nodejs.org/). Just download and install the package that's available for your operating system [from the Node website](http://nodejs.org/).

Then, to install [Bower, the JavaScript package manager](http://bower.io/), run:

`npm install bower -g`

Then, to install the project's JavaScript dependencies, run:

`bower install` inside of the `public` directory.

You should see output relating to Bootstrap, jQuery, and so on.

### 3. Install the Perl dependencies

From here, if you don't have a global install of [cpanm](https://github.com/miyagawa/cpanminus), you'll want to install that with the command `plenv install-cpanm` (this assumes that you installed Perl with `plenv` as described above).

Next, to localize the libraries that the project requires, you'll want to install [Carton](https://github.com/perl-carton/carton):

`cpanm install Carton`

Then install the project requirements into a local directory so that you know you're using the right ones:

`cd support.thetyee.ca`

`carton install`

At this point, you should probably go make a coffee or get a glass of wine or something, as it'll probably take a while to install all of the dependencies.

When that finishes, you should have a `local` directory full of libraries.

### 4. Get and edit the configuration files

Get them from the secret repository!

You'll need:

* app.development.json
* sqitch/sqitch.conf

You'll want to udpate the values in `app.development.json` and `sqitch/sqitch.conf` to point to your local PostgreSQL database.


### 5. Load the database schema with Sqitch

Next, you'll want to load the required table(s) into PostgreSQL using sqitch. You can do that like so:

`cd sqitch`
`carton exec sqitch deploy`



If that worked, you should see something like:

Deploying changes to db:pg:tyeedb_dev
  + schema ................ ok
  + transactions @v0.2.6 .. ok
  + transactions @v0.3.0 .. ok
  + transactions @v0.3.4 .. ok
  + transactions @v1.0.4 .. ok
  + transactions @v1.0.5 .. ok
  + transactions .......... ok

### 6. Start the development server

At this point you should have everything needed to start developing. Run the app in development mode with:

`carton exec morbo app.pl`

And, if everything worked, you should see:

`Server available at http://127.0.0.1:3000.`

### 7. Bask in the glory of local development!

Do NOT pass go. Do NOT collect $200. Just enjoy the moment.

The development server will reload the app when any of the files are edited. So you can just edit the template files and the single-file application to your needs and refresh your browser to see the results.

Errors will be written to your terminal, as well as shown in the browser.

### 8. Send a pull request with the changes

When you're done making changes, create a new pull request pointing from the branch that you're working on locally (probaby `develop`) pointing to the `develop` branch at https://github.com/phillipadsmith/support.thetyee.ca

Submit the pull request and congratulate yourself on a job well done. :)

## Updating the preview site

### 1. Updating the app

First, you need to update the files on the server.

Using terminal, log in to the remote server (thetyee.ca)

`cd preview.support.thetyee.ca/www/`

Make sure you're on the develop branch:

`git branch`

Then sync up!

`git pull`

Then, redeploy the application:

`MOJO_MODE='preview' MOJO_LOG_LEVEL='debug' hypnotoad app.pl`

MOJE_MODE tells the app which config file to use. I.e. `MOJO_MODE='preview'` will look for the app.preview.json file.

### 2. Updating the static files

Static files stored on a different part of the server.

To access, log in to thetyee.ca

`cd static.thetyee.ca/www/support/[version]`

`git pull`

### 3. Version Control

For more substantial changes, you'll want to create a new directory.

Log in to thetyee.ca

`cd static.thetyee.ca/www/support`

`git clone https://github.com/phillipadsmith/support.thetyee.ca-static.git v[version number]`

`cd v[version number]`

`bower install`




