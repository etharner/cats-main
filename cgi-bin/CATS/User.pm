package CATS::User;

use strict;
use warnings;

use Encode;
use Storable;

use CATS::Config;
use CATS::Constants;
use CATS::ContestParticipate qw(get_registered_contestant);
use CATS::Countries;
use CATS::DB;
use CATS::Form qw(validate_string_length validate_integer);
use CATS::Misc qw(init_template msg url_f $t $is_root);
use CATS::Web qw(param);


sub new
{
    my ($class) = @_;
    $class = ref $class if ref $class;
    my $self = {};
    bless $self, $class;
    $self;
}


sub parse_params
{
   $_[0]->{$_} = param($_) || '' for param_names(), qw(password1 password2);
   $_[0];
}


sub load
{
    my ($self, $id, $extra_fields) = @_;
    my @fields = (param_names(), @{$extra_fields || []});
    @$self{@fields} = $dbh->selectrow_array(qq~
        SELECT ~ . join(', ' => @fields) . q~
            FROM accounts WHERE id = ?~, { Slice => {} },
        $id
    ) or return;
    $self->{country} ||= $CATS::Countries::countries[0]->{id};
    $self->{settings} = Storable::thaw($self->{frozen_settings} = $self->{settings})
        if $self->{settings};
    $_->{selected} = $_->{id} eq $self->{country} for @CATS::Countries::countries;
    $self;
}


sub values { @{$_[0]}{param_names()} }


sub add_to_contest
{
    my %p = @_;
    $p{contest_id} && $p{account_id} or die;
    $dbh->do(qq~
        INSERT INTO contest_accounts (
            id, contest_id, account_id, is_jury, is_pop, is_hidden, is_ooc, is_remote,
            is_virtual, diff_time
        ) VALUES(?,?,?,?,?,?,?,?,?,?)~, {},
        new_id, $p{contest_id}, $p{account_id}, 0, 0, 0, $p{is_ooc}, $p{is_remote} || 0,
        0, 0
    );
}


sub generate_login
{
    my $login_num;

    if ($CATS::Config::db_dsn =~ /Firebird/) {
        $login_num = $dbh->selectrow_array('SELECT GEN_ID(login_seq, 1) FROM RDB$DATABASE');
    }
    elsif ($cats_db::db_dsn =~ /Oracle/) {
        $login_num = $dbh->selectrow_array(qq~SELECT login_seq.nextval FROM DUAL~);
    }
    $login_num or die;

    return "team$login_num";
}


sub new_frame
{
    init_template('users_new.html.tt');
    $t->param(
        login => generate_login,
        countries => \@CATS::Countries::countries,
        href_action => url_f('users'),
        is_root => $is_root
    );
}


sub param_names ()
{qw(
    login team_name capitan_name email country motto home_page icq_number
    city affiliation affiliation_year
    git_author_name git_author_email
    restrict_ips
)}


sub any_official_contest_by_team
{
    my ($account_id) = @_;
    $dbh->selectrow_array(qq~
        SELECT FIRST 1 C.title FROM contests C
            INNER JOIN contest_accounts CA ON CA.contest_id = C.id
            INNER JOIN accounts A ON A.id = CA.account_id
            WHERE C.is_official = 1 AND CA.is_ooc = 0 AND CA.is_jury = 0 AND
            C.finish_date < CURRENT_TIMESTAMP AND A.id = ?~, undef,
        $account_id);
}


sub validate_params
{
    my ($self, %p) = @_;

    validate_string_length($self->{login}, 616, 1, 50) or return;
    validate_string_length($self->{team_name}, 800, 1, 100) or return;
    validate_string_length($self->{capitan_name}, 801, 0, 100) or return;
    validate_string_length($self->{motto}, 802, 0, 100) or return;
    validate_string_length($self->{email}, 803, 0, 50) or return;
    validate_string_length($self->{icq_number}, 804, 0, 50) or return;
    validate_string_length($self->{home_page}, 805, 0, 100) or return;
    validate_string_length($self->{affiliation}, 807, 0, 100) or return;
    validate_integer($self->{affiliation_year}, 807, allow_empty => 1, min => 1900, max => 2100) or return;
    $self->{affiliation_year} or $self->{affiliation_year} = undef;

    if ($p{validate_password}) {
        validate_string_length($self->{password1}, 806, 1, 72) or return;
        $self->{password1} eq $self->{password2}
            or return msg(1033);
    }

    my $old_login = '';
    if ($p{id} && !$p{allow_official_rename}) {
        ($old_login, my $old_team_name) = $dbh->selectrow_array(qq~
            SELECT login, team_name FROM accounts WHERE id = ?~, undef,
            $p{id});
        if (($old_team_name ne $self->{team_name}) &&
            (my ($official_contest) = any_official_contest_by_team($p{id})))
        {
            # If the team participated in the official contest, forbid it to rename itself.
            return msg(1086, $official_contest);
        }
    }

    return $old_login eq $self->{login} || $self->validate_login($p{id});
}


sub validate_login
{
    my ($self, $id) = @_;
    my $dups = $dbh->selectcol_arrayref(qq~
        SELECT id FROM accounts WHERE login = ?~, {}, $self->{login}) or return 1;
    # Several logins, or a single login with different id => error.
    return
        @$dups > 1 || @$dups == 1 && (!$id || $id != $dups->[0]) ? msg(1103) : 1;
}


sub insert
{
    my ($self, $contest_id, %p) = @_;
    my $training_contests = $dbh->selectall_arrayref(qq~
        SELECT id, closed FROM contests WHERE ctype = 1 AND closed = 0~,
        { Slice => {} });
    @$training_contests or return msg(1092);

    my $aid = new_id;
    my $new_settings = $p{save_settings} ? Storable::freeze($CATS::Misc::settings) : '';
    $dbh->do(qq~
        INSERT INTO accounts (
            id, srole, passwd, settings, ~ . join (', ', param_names()) . q~
        ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)~, {},
        $aid, $cats::srole_user, $self->{password1}, $new_settings, $self->values
    );
    add_to_contest(contest_id => $_->{id}, account_id => $aid, is_ooc => 1)
        for @$training_contests;
    if ($contest_id && !grep $_->{id} == $contest_id, @$training_contests) {
        add_to_contest(contest_id => $contest_id, account_id => $aid, is_ooc => $p{is_ooc} // 1);
    }

    $dbh->commit if $p{commit} // 1;
    1;
}

sub trim { s/^\s+|\s+$//; $_; }

# (Mass-)register users by jury.
sub register_by_login
{
    my ($login, $contest_id) = @_;
    $login = Encode::decode_utf8($login);
    my @logins = map trim, split(/,/, $login || '') or return msg(1101);
    my %aids;
    for (@logins) {
        length $_ <= 50 or return msg(1101);
        my ($aid) = $dbh->selectrow_array(qq~
            SELECT id FROM accounts WHERE login = ?~, undef, $_);
        $aid or return msg(1118, $_);
        !get_registered_contestant(contest_id => $contest_id, account_id => $aid)
            or return msg(1120, $_);
        $aids{$aid} = 1;
    }
    %aids or return msg(1118);
    add_to_contest(contest_id => $contest_id, account_id => $_, is_remote => 1, is_ooc => 1)
        for keys %aids;
    $dbh->commit;
    msg(1119, join ',', @logins);
}


sub make_sid {
    my @ch = ('A'..'Z', 'a'..'z', '0'..'9');
    join '', map { $ch[rand @ch] } 1..30;
}

1;
