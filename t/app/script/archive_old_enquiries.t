use FixMyStreet::TestMech;
use FixMyStreet::Script::ArchiveOldEnquiries;

my $mech = FixMyStreet::TestMech->new();

$mech->clear_emails_ok;

my $user = $mech->create_user_ok('test@example.com', name => 'Test User');
my $oxfordshire = $mech->create_body_ok(2237, 'Oxfordshire County Council');
my $west_oxon = $mech->create_body_ok(2420, 'West Oxfordshire District Council');

my $opts = {
    commit => 1,
    body => $oxfordshire->id,
    cobrand => 'oxfordshire',
    closure_cutoff => "2015-01-01 00:00:00",
    email_cutoff => "2016-01-01 00:00:00",
    user => $user->id,
};

subtest 'sets reports to the correct status' => sub {
    FixMyStreet::override_config {
          ALLOWED_COBRANDS => [ 'oxfordshire' ],
    }, sub {
        my ($report) = $mech->create_problems_for_body(1, $oxfordshire->id, 'Test', {
            areas      => ',2237,',
            user_id    => $user->id,
        });

        my ($report1) = $mech->create_problems_for_body(1, $oxfordshire->id . "," .$west_oxon->id, 'Test', {
            areas      => ',2237,',
            lastupdate => '2015-12-01 07:00:00',
            user       => $user,
        });

        my ($report2) = $mech->create_problems_for_body(1, $oxfordshire->id, 'Test 2', {
            areas      => ',2237,',
            lastupdate => '2015-12-01 08:00:00',
            user       => $user,
            state      => 'investigating',
        });

        my ($report3, $report4) = $mech->create_problems_for_body(2, $oxfordshire->id, 'Test', {
            areas      => ',2237,',
            lastupdate => '2014-12-01 07:00:00',
            user       => $user,
        });

        my ($report5) = $mech->create_problems_for_body(1, $oxfordshire->id . "," .$west_oxon->id, 'Test', {
            areas      => ',2237,',
            lastupdate => '2014-12-01 07:00:00',
            user       => $user,
            state      => 'in progress'
        });

        FixMyStreet::Script::ArchiveOldEnquiries::archive($opts);

        $report->discard_changes;
        $report1->discard_changes;
        $report2->discard_changes;
        $report3->discard_changes;
        $report4->discard_changes;
        $report5->discard_changes;

        is $report1->state, 'closed', 'Report 1 has been set to closed';
        is $report2->state, 'closed', 'Report 2 has been set to closed';
        is $report3->state, 'closed', 'Report 3 has been set to closed';
        is $report4->state, 'closed', 'Report 4 has been set to closed';
        is $report5->state, 'closed', 'Report 5 has been set to closed';

        my $comment = $report1->comments->first;
        is $comment->problem_state, 'closed';

        is $report->state, 'confirmed', 'Recent report has been left alone';
    };
};

subtest 'marks alerts as sent' => sub {
    FixMyStreet::override_config {
          ALLOWED_COBRANDS => [ 'oxfordshire' ],
    }, sub {
        my ($report) = $mech->create_problems_for_body(1, $oxfordshire->id, 'Test', {
            areas      => ',2237,',
            lastupdate => '2015-12-01 07:00:00',
            user_id    => $user->id,
        });
        my $alert = FixMyStreet::DB->resultset('Alert')->find_or_create(
            {
                user => $user,
                parameter => $report->id,
                alert_type => 'new_updates',
                whensubscribed => '2015-12-01 07:00:00',
                confirmed => 1,
                cobrand => 'default',
            }
        );
        is $alert->alerts_sent->count, 0, 'Nothing has been sent for this alert';

        FixMyStreet::Script::ArchiveOldEnquiries::archive($opts);

        $report->discard_changes;

        is $report->state, 'closed', 'Report has been set to closed';

        is $alert->alerts_sent->count, 1, 'Alert marked as sent for this report';

        my $alert_sent = $alert->alerts_sent->first;
        my $comment = $report->comments->first;
        is $alert_sent->parameter, $comment->id, 'AlertSent created for new comment';
    };
};

subtest 'sends emails to a user' => sub {
    FixMyStreet::override_config {
      ALLOWED_COBRANDS => [ 'oxfordshire' ],
    }, sub {
        $mech->clear_emails_ok;
        $mech->email_count_is(0);

        $mech->create_problems_for_body(1, $oxfordshire->id, 'Shiny new report', {
            areas      => ',2237,',
            user       => $user,
        });

        $mech->create_problems_for_body(1, $oxfordshire->id, 'Problem the first', {
            areas      => ',2237,',
            lastupdate => '2015-12-01 07:00:00',
            user       => $user,
        });

        $mech->create_problems_for_body(1, $oxfordshire->id, 'Problem the second', {
            areas      => ',2237,',
            lastupdate => '2015-12-01 07:00:00',
            user       => $user,
        });

        $mech->create_problems_for_body(1, $oxfordshire->id, 'Problem the third', {
            areas      => ',2237,',
            lastupdate => '2015-12-01 07:00:00',
            user       => $user,
        });

        $mech->create_problems_for_body(1, $oxfordshire->id, 'Really old report', {
            areas      => ',2237,',
            lastupdate => '2014-12-01 07:00:00',
            user       => $user,
        });

        FixMyStreet::Script::ArchiveOldEnquiries::archive($opts);

        my @emails = $mech->get_email;
        $mech->email_count_is(1);

        my $email = $emails[0];
        my $body = $mech->get_text_body_from_email($email);

        like $body, qr/Problem the first/, 'Email body matches report name';
        like $body, qr/Problem the second/, 'Email body matches report name';
        like $body, qr/Problem the third/, 'Email body matches report name';

        unlike  $body, qr/Shiny new report/, 'Email body does not have new report';
        unlike  $body, qr/Really old report/, 'Email body does not have old report';
    };
};

subtest 'user with old reports does not get email' => sub {
  $mech->clear_emails_ok;
  $mech->email_count_is(0);

  $mech->create_problems_for_body(4, $oxfordshire->id, 'Really old report', {
      areas      => ',2237,',
      lastupdate => '2014-12-01 07:00:00',
      user       => $user,
  });

  FixMyStreet::Script::ArchiveOldEnquiries::archive($opts);

  my @emails = $mech->get_email;
  $mech->email_count_is(0);
};

subtest 'user with new reports does not get email' => sub {
  $mech->clear_emails_ok;
  $mech->email_count_is(0);

  $mech->create_problems_for_body(4, $oxfordshire->id, 'Shiny new report', {
      areas      => ',2237,',
      user       => $user,
  });

  FixMyStreet::Script::ArchiveOldEnquiries::archive($opts);

  $mech->email_count_is(0);
};

done_testing();
