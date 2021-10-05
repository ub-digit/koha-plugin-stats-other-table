package Koha::Plugin::Se::Gu::Ub::StatsOtherTable;

## It's good practive to use Modern::Perl
use Modern::Perl;

## Required for all plugins
use base qw(Koha::Plugins::Base);
use C4::Context;
use Koha::Patrons;
use Koha::Checkouts;
use Koha::Biblios;
use Data::Dumper;

## Here we set our plugin version
our $VERSION = "1.0.0";

## Here is our metadata, some keys are required, some are optional
our $metadata = {
    name            => 'Stats to another table',
    author          => 'Stefan Berndtsson',
    date_authored   => '2019-03-23',
    date_updated    => "2019-03-23",
    minimum_version => '17.06.00.028',
    maximum_version => undef,
    version         => $VERSION,
    description     => 'Write statistics to a different table ',
};

## This is the minimum code required for a plugin's 'new' method
## More can be added, but none should be removed
sub new {
    my ( $class, $args ) = @_;

    ## We need to add our metadata here so our base class can access it
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    ## Here, we call the 'new' method for our base class
    ## This runs some additional magic and checking
    ## and returns our actual $self
    my $self = $class->SUPER::new($args);

    return $self;
}

sub configure {
    my ($self, $args) = @_;
    my $cgi = $self->{'cgi'};

    if ($cgi->param('save')) {
        # Save
        $self->store_data({
            tablename => $cgi->param('tablename') || '',
            create_table_if_missing => $cgi->param('create_table_if_missing')
        });
        $self->go_home();
    }
    else {
        my $template = $self->get_template({ file => 'configure.tt' });
        $template->param(
            tablename => $self->retrieve_data('tablename'),
            create_table_if_missing => $self->retrieve_data('create_table_if_missing')
        );
        print $cgi->header(-charset => 'utf-8');
        print $template->output();
    }
}

sub update_stats {
    my ($self, $args) = @_;

#    print STDERR Dumper(["DEBUG", $args]);
    my $tablename = $self->retrieve_data('tablename');
    my $create_table_if_missing = $self->retrieve_data('create_table_if_missing');

    $self->create_table_if_missing($tablename, $create_table_if_missing);
    
    # Only write to table if tablename is specified
    if($tablename) {
        AlternateUpdateStats($tablename, $args);
    }

    # Need to return args so that chaining of plugins work.
    return $args;
}

# For now simply a copy of the current UpdateStats with some tweaks
sub AlternateUpdateStats {
    my ($tablename, $params) = @_;
    
# get the parameters
    my $branch            = $params->{branch};
    my $type              = $params->{type};
    my $borrowernumber    = exists $params->{borrowernumber} ? $params->{borrowernumber} : '';
    my $itemnumber        = exists $params->{itemnumber}     ? $params->{itemnumber}     : undef;
    my $amount            = exists $params->{amount}         ? $params->{amount}         : 0;
    my $other             = exists $params->{other}          ? $params->{other}          : '';
    my $itemtype          = exists $params->{itemtype}       ? $params->{itemtype}       : '';
    my $location          = exists $params->{location}       ? $params->{location}       : undef;
    my $ccode             = exists $params->{ccode}          ? $params->{ccode}          : '';
    my $biblio;
    my $biblionumber;
    my $item;
    my $title;
    my $author;
    my $callno;
    my $issue_note;
    my $issue_auto_renew;

    my $logged_in_borrowernumber;
    my $current_user = C4::Context->userenv;
    if($current_user) {
        $logged_in_borrowernumber = $current_user->{'number'};
    }
    
    # Add categorycode field if we have a borrowernumber
    my $categorycode = '';
    if($borrowernumber) {
	my $patron = Koha::Patrons->find($borrowernumber);
	if($patron) {
	    $categorycode = $patron->categorycode();
	}
    }
    
    if($itemnumber) {
        $item = Koha::Items->find($itemnumber);
        if($item) {
            $callno = $item->itemcallnumber();
            $biblio = $item->biblio();
            $biblionumber = $item->biblionumber();
            if(!$location) {
                $location = $item->location();
            }
            if($biblio) {
                $title = $biblio->title();
                $author = $biblio->author();
            }
            if($type eq "issue" || $type eq "renew") {
                my $issue = Koha::Checkouts->find({itemnumber => $itemnumber, borrowernumber => $borrowernumber});
                if($issue) {
                    $issue_note = $issue->note();
                    $issue_auto_renew = $issue->auto_renew();
                    if($type eq "renew") {
                        $other = $issue->issuedate();
                    }
                }
            }
        }
    }
    
    my $dbh = C4::Context->dbh;
    my $tablename_sql = $dbh->quote_identifier($tablename);
    my $sth = $dbh->prepare(
        "INSERT INTO $tablename_sql
        (datetime,
         branch, type, value, other,
         itemnumber, itemtype, location, 
         ccode, biblionumber, title, author, 
         callno, categorycode, borrowernumber, issue_note, issue_auto_renew)
         VALUES (now(),?,?,?,?, ?,?,?,?, ?,?,?,?, ?,?, ?, ?)"
    );
    $sth->execute(
        $branch,     $type,     $amount,   $other,
        $itemnumber, $itemtype, $location, 
        $ccode, $biblionumber, $title, $author,
        $callno, $categorycode, $logged_in_borrowernumber, $issue_note, $issue_auto_renew
    );
}

sub create_table_if_missing {
    my ($self, $tablename, $create_table_if_missing) = @_;

    # If we shouldn't try to create table or if no tablename is provided, or if table exists, exit.
    if(!$create_table_if_missing || !$tablename || $self->table_exists()) {
        return;
    }

    # Ok, everything says table should be created.
    my $dbh = C4::Context->dbh;
    my $tablename_sql = $dbh->quote_identifier($tablename);
    my $sth = $dbh->prepare(<<"END_SQL");
    CREATE TABLE $tablename_sql (
      datetime datetime, 
      branch varchar(10),
      value double(16,4),
      type varchar(16),
      other longtext,
      itemnumber int(11),
      itemtype varchar(10),
      location varchar(80),
      ccode varchar(80),
      biblionumber int(11),
      title longtext,
      author longtext,
      callno longtext,
      categorycode varchar(10),
      borrowernumber int(11),
      issue_note longtext,
      issue_auto_renew tinyint(1)
    )
END_SQL
    $sth->execute();
}

# Check if table exists. Returns 0 if no tablename is provided, or if table does not exist, otherwise returns 1.
sub table_exists {
    my ($self) = @_;

    my $tablename = $self->retrieve_data('tablename');

    if(!$tablename) {
        return 0;
    }
    
    my $dbh = C4::Context->dbh;
    my $sth = $dbh->prepare("SELECT COUNT(*) AS count FROM information_schema.tables WHERE table_name = ?");
    $sth->execute($tablename);

    my $row = $sth->fetchrow_hashref;
#    print STDERR Dumper(["OTHERTABLE", $row]);
    if($row->{count} == 1) {
        return 1;
    } else {
        return 0;
    }
}
