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

sub after_hold_action {
    my ($self, $params) = @_;

    my $action = $params->{action};
    my $payload = $params->{payload};
    my $hold = $payload->{hold};

    my $tablename = $self->setup();
    return unless($tablename);

    AlternateUpdateStats($tablename, {
        branch => C4::Context->userenv->{'branch'},
        type => "hold_".$action,
        biblio => $hold->biblio(),
        other => $hold->branchcode(),
        itemnumber => $hold->itemnumber,
        borrowernumber => $hold->borrowernumber,
        reserve_found_value => $hold->found
    });
}

sub after_account_action {
    my ($self, $params) = @_;

    my $action = $params->{action};
    my $payload = $params->{payload};
    my $line = $payload->{line};
    my $type = $payload->{type};

    my $tablename = $self->setup();
    return unless($tablename);

    return unless($action eq "add_credit");

    AlternateUpdateStats($tablename, {
        branch => $line->branchcode(),
        type => $type,
        amount => $line->amount(),
        other => $line->interface(),
        itemnumber => $line->itemnumber,
        borrowernumber => $line->borrowernumber
    });
}

sub after_circ_action {
    my ($self, $params) = @_;

    my $action = $params->{action};
    my $payload = $params->{payload};

    my $tablename = $self->setup();
    return unless($tablename);

    if($action eq "checkout") {
        circ_action_checkout($tablename, $payload->{checkout}, $payload->{type});
    }
    if($action eq "checkin") {
        circ_action_checkin($tablename, $payload->{checkout});
    }
    if($action eq "checkin_no_issue") {
        circ_action_checkin_no_issue($tablename, $payload->{checkin});
    }
    if($action eq "renewal") {
        circ_action_renewal($tablename, $payload->{checkout});
    }
}

sub circ_action_checkout {
    my ($tablename, $checkout, $type) = @_;
    AlternateUpdateStats($tablename, {
        branch => C4::Context->userenv->{'branch'},
        type => $type,
        itemnumber => $checkout->itemnumber,
        itemtype => $checkout->item->effective_itemtype,
        location => $checkout->item->location,
        borrowernumber => $checkout->borrowernumber,
        ccode => $checkout->item->ccode
    });
}

sub circ_action_checkin {
    my ($tablename, $checkout) = @_;
    AlternateUpdateStats($tablename, {
        branch => C4::Context->userenv->{'branch'},
        type => 'return',
        itemnumber => $checkout->itemnumber,
        itemtype => $checkout->item->effective_itemtype,
        location => $checkout->item->location,
        borrowernumber => $checkout->borrowernumber,
        ccode => $checkout->item->ccode,
        issue_note => $checkout->note,
        issue_auto_renew => $checkout->auto_renew
    });
}

sub circ_action_checkin_no_issue {
    my ($tablename, $item) = @_;
    AlternateUpdateStats($tablename, {
        branch => C4::Context->userenv->{'branch'},
        type => 'return',
        itemnumber => $item->itemnumber,
        itemtype => $item->effective_itemtype,
        location => $item->location,
        ccode => $item->ccode
    });
}

sub circ_action_renewal {
    my ($tablename, $checkout) = @_;
    AlternateUpdateStats($tablename, {
        branch => C4::Context->userenv->{'branch'},
        type => 'renew',
        itemnumber => $checkout->itemnumber,
        itemtype => $checkout->item->effective_itemtype,
        location => $checkout->item->location,
        borrowernumber => $checkout->borrowernumber,
        ccode => $checkout->item->ccode,
        issue_note => $checkout->note,
        issue_auto_renew => $checkout->auto_renew
    });
}

sub setup {
    my ($self) = @_;
    my $tablename = $self->retrieve_data('tablename');
    my $create_table_if_missing = $self->retrieve_data('create_table_if_missing');

    $self->create_table_if_missing($tablename, $create_table_if_missing);
    return $tablename;
}

sub AlternateUpdateStats {
    my ($tablename, $params) = @_;
    
    my $branch              = $params->{branch};
    my $type                = $params->{type};
    my $borrowernumber      = exists $params->{borrowernumber} ? $params->{borrowernumber} : '';
    my $itemnumber          = exists $params->{itemnumber}     ? $params->{itemnumber}     : undef;
    my $amount              = exists $params->{amount}         ? $params->{amount}         : 0;
    my $other               = exists $params->{other}          ? $params->{other}          : '';
    my $itemtype            = exists $params->{itemtype}       ? $params->{itemtype}       : '';
    my $location            = exists $params->{location}       ? $params->{location}       : undef;
    my $ccode               = exists $params->{ccode}          ? $params->{ccode}          : '';
    my $biblio              = exists $params->{biblio}         ? $params->{biblio}         : undef;
    my $biblionumber;
    my $item;
    my $title;
    my $author;
    my $callno;
    my $issue_note          = exists $params->{issue_note}       ? $params->{issue_note} : undef;
    my $issue_auto_renew    = exists $params->{issue_auto_renew} ? $params->{issue_auto_renew} : undef;
    my $reserve_found_value = exists $params->{reserve_found_value} ? $params->{reserve_found_value} : undef;

    my $logged_in_borrowernumber;
    my $current_user = C4::Context->userenv;
    if($current_user) {
        $logged_in_borrowernumber = $current_user->{'number'};
    }
    
    # Add categorycode field and organisation attribute value if we have a borrowernumber
    my $categorycode = '';
    my $organisation = '';
    if($borrowernumber) {
        my $patron = Koha::Patrons->find($borrowernumber);
        if($patron) {
            $categorycode = $patron->categorycode();

            my $attribute = $patron->get_extended_attribute('ORG');
            $organisation = $attribute->attribute if defined $attribute;
        }
    }
    
    if(!$item && $itemnumber) {
        $item = Koha::Items->find($itemnumber);
    }

    if(!$biblio && $item) {
        $biblio = $item->biblio();
    }

    if($biblio) {
        $title = $biblio->title();
        $author = $biblio->author();
        $biblionumber = $biblio->biblionumber();
    }

    if($item) {
        $callno = $item->itemcallnumber();
        if(!$location) {
            $location = $item->location();
        }
        if(!$ccode) {
            $ccode = $item->ccode();
        }
        if(!$itemtype) {
            $itemtype = $item->effective_itemtype;
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
    
    my $dbh = C4::Context->dbh;
    my $tablename_sql = $dbh->quote_identifier($tablename);
    my $sth = $dbh->prepare(
        "INSERT INTO $tablename_sql
        (datetime,
         branch, type, value, other,
         itemnumber, itemtype, location, 
         ccode, biblionumber, title, author, 
         callno, categorycode, organisation,
         borrowernumber, issue_note, issue_auto_renew, reserve_found_value)
         VALUES (now(),?,?,?,?, ?,?,?,?, ?,?,?,?, ?,?,?,?, ?, ?)"
    );
    $sth->execute(
        $branch,     $type,     $amount,   $other,
        $itemnumber, $itemtype, $location, 
        $ccode, $biblionumber, $title, $author,
        $callno, $categorycode, $organisation,
        $logged_in_borrowernumber, $issue_note, $issue_auto_renew,
        $reserve_found_value
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
      organisation varchar(255),
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
