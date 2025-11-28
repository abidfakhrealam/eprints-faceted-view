package EPrints::Plugin::Screen::SolrFacetedBrowse;

use strict;
use warnings;

our @ISA = ('EPrints::Plugin::Screen');

use EPrints::Plugin::Screen;
use LWP::UserAgent;
use JSON qw( decode_json encode_json );
use URI::Escape qw( uri_escape );
use Time::HiRes qw( gettimeofday tv_interval );
use EPrints::XML;
use EPrints::Utils;

sub new
{
    my( $class, %params ) = @_;

    my $self = $class->SUPER::new( %params );

    # Visible to logged-in users
    $self->{priv} = undef;

    $self->{appears} = [
        {
            place    => "key_tools",
            position => 500,
        },
    ];

    # include facet_preview + autocomplete actions
    $self->{actions} = [qw/ apply clear export facet_preview autocomplete /];
    $self->{disable} = 0;

    return $self;
}

sub can_be_viewed
{
    my( $self ) = @_;
    return 1;
}

sub properties_from
{
    my( $self ) = @_;
    my $session = $self->{session};

    $self->{processor}->{q} = $session->param( "q" );
    $self->{processor}->{q} = "*:*"
        if !defined $self->{processor}->{q} || $self->{processor}->{q} eq "";

    my $page = $session->param( "page" ) || 1;
    $page = 1 if $page < 1 || $page !~ /^\d+$/;
    $self->{processor}->{page} = $page;

    # Sort whitelist
    my $sort = $session->param( "sort" ) || "score desc";
    my %allowed_sorts = (
        "score desc"     => "Relevance",
        "year_i desc"    => "Newest first",
        "year_i asc"     => "Oldest first",
        "title_sort asc" => "Title A–Z",
        "title_sort desc"=> "Title Z–A",
    );
    $sort = "score desc" unless exists $allowed_sorts{$sort};
    $self->{processor}->{sort} = $sort;

    my @fq = $session->param( "fq" );
    $self->{processor}->{fq} = \@fq;
}

sub allow_apply { return 1; }
sub action_apply { }

sub allow_clear { return 1; }
sub action_clear
{
    my( $self ) = @_;
    $self->{processor}->{q}    = "*:*";
    $self->{processor}->{page} = 1;
    $self->{processor}->{fq}   = [];
    $self->{processor}->{sort} = "score desc";
}

sub allow_export { return 1; }
sub action_export
{
    my( $self ) = @_;
    my $session = $self->{session};

    my $q    = $self->{processor}->{q} || "*:*";
    my $fqs  = $self->{processor}->{fq} || [];
    my $sort = $self->{processor}->{sort} || "score desc";

    my( $solr, $err ) = $self->_run_solr_query( $q, $fqs, 0, 10000, $sort );

    if( defined $err )
    {
        $session->get_repository->log( "Solr export failed: $err" );
        $self->{processor}->add_message( "error", $session->html_phrase( "solr/export_failed" ) );
        return;
    }

    $self->_export_results( $solr );
}

sub allow_autocomplete { return 1; }
sub action_autocomplete
{
    my( $self ) = @_;
    my $session = $self->{session};
    my $repo    = $session->get_repository;

    my $term = $session->param( "term" ) // "";
    $term =~ s/^\s+|\s+$//g;

    $session->get_http->send_http_header( "application/json; charset=utf-8" );
    binmode STDOUT, ":utf8";

    if( $term eq "" )
    {
        print "[]";
        exit;
    }

    my( $suggest, $err ) = $self->_run_solr_suggest( $term );
    if( defined $err )
    {
        $repo->log( "Solr autocomplete failed: $err" );
        print "[]";
        exit;
    }

    my @terms;
    my $root = $suggest->{suggest} || {};

    foreach my $suggester ( keys %$root )
    {
        my $sugg = $root->{$suggester};
        next unless ref $sugg eq 'HASH';

        foreach my $key ( keys %$sugg )
        {
            my $entry = $sugg->{$key};
            next unless ref $entry eq 'HASH';

            my $list = $entry->{suggestions} || [];
            next unless ref $list eq 'ARRAY';

            foreach my $s ( @$list )
            {
                next unless ref $s eq 'HASH';
                next unless defined $s->{term};
                push @terms, $s->{term};
            }
        }
    }

    my %seen;
    @terms = grep { !$seen{$_}++ } @terms;

    print encode_json( \@terms );
    exit;
}

sub render
{
    my( $self ) = @_;
    my $session = $self->{session};
    my $repo    = $session->get_repository;

    my $q    = $self->{processor}->{q} || "*:*";
    my $page = $self->{processor}->{page} || 1;
    my $fqs  = $self->{processor}->{fq} || [];
    my $sort = $self->{processor}->{sort} || "score desc";

    my $conf  = $repo->config( "solr" ) || {};
    my $rows  = $conf->{rows} || 20;
    my $start = ($page - 1) * $rows;

    my $t0 = [gettimeofday];
    my( $solr, $err ) = $self->_run_solr_query( $q, $fqs, $start, $rows, $sort );
    my $elapsed = tv_interval( $t0 );

    my $frag = $session->make_doc_fragment;

    my $h = $session->make_element( "h2", class => "ep_solr_title" );
    $h->appendChild( $session->make_text( "Repository Search" ) );
    $frag->appendChild( $h );

    if( defined $err )
    {
        my $p = $session->make_element( "p", class => "ep_error" );
        $p->appendChild( $session->make_text( $err ) );
        $frag->appendChild( $p );
        return $frag;
    }

    my $outer = $session->make_element(
        "div",
        id    => "ep_solr_facetview",
        class => "facetview facetview-solr",
        "data-loading" => "false"
    );

    my $search_box = $self->_render_search_form;
    $outer->appendChild( $search_box );

    my $summary = $self->_render_results_summary( $solr, $page, $rows, $elapsed );
    $outer->appendChild( $summary );

    my $layout = $session->make_element(
        "div",
        class => "ep_solr_layout"
    );

    my $facets_dom  = $self->_render_facets( $solr, $fqs, $q );
    my $results_dom = $self->_render_results( $solr, $q, $fqs, $page, $rows, $sort );

    $layout->appendChild( $facets_dom );
    $layout->appendChild( $results_dom );

    $outer->appendChild( $layout );
    $frag->appendChild( $outer );

    return $frag;
}

########################
# Internal helpers
########################

sub _run_solr_query
{
    my( $self, $q, $fqs, $start, $rows, $sort ) = @_;

    my $session  = $self->{session};
    my $repo     = $session->get_repository;
    my $conf     = $repo->config( "solr" ) || {};
    my $endpoint = $conf->{endpoint};
    return (undef, "Solr endpoint not configured") unless $endpoint;

    my @params;
    push @params, "q=" . uri_escape( $q );
    push @params, "wt=json";
    push @params, "start=$start";
    push @params, "rows=$rows";
    push @params, "sort=" . uri_escape( $sort ) if $sort;

    push @params, "facet=true";
    push @params, "facet.mincount=1";
    push @params, "facet.limit=" . ( $conf->{facet_limit} || 50 );

    foreach my $facet ( @{$conf->{facets} || []} )
    {
        push @params, "facet.field=" . uri_escape( $facet->{field} );
    }

    foreach my $fq ( @$fqs )
    {
        push @params, "fq=" . uri_escape( $fq );
    }

    push @params, "hl=true";
    push @params, "hl.fl=*";
    push @params, "hl.simple.pre=<mark>";
    push @params, "hl.simple.post=</mark>";

    my $url = $endpoint;
    $url =~ s{/+$}{};
    $url .= "/select?" . join( "&", @params );

    my $ua = LWP::UserAgent->new(
        timeout => $conf->{timeout} || 30,
        agent   => "EPrints-Solr-Plugin/1.0"
    );

    if( my $auth = $conf->{auth} ) {
        $ua->credentials(
            $auth->{hostport},
            $auth->{realm} || "Solr",
            $auth->{username},
            $auth->{password}
        );
    }

    my $res = $ua->get( $url );

    unless( $res->is_success )
    {
        my $error_msg = "Solr query failed: " . $res->status_line;
        $repo->log( $error_msg );
        return (undef, $error_msg);
    }

    my $data = eval { decode_json( $res->decoded_content ) };
    if( $@ )
    {
        my $error_msg = "Invalid JSON from Solr: $@";
        $repo->log( $error_msg );
        return (undef, $error_msg);
    }

    return ($data, undef);
}

sub _run_solr_suggest
{
    my( $self, $term ) = @_;

    my $session  = $self->{session};
    my $repo     = $session->get_repository;
    my $conf     = $repo->config( "solr" ) || {};
    my $endpoint = $conf->{endpoint};
    return (undef, "Solr endpoint not configured") unless $endpoint;

    my $sconf      = $conf->{suggest} || {};
    my $handler    = $sconf->{handler}   || "suggest";
    my $dictionary = $sconf->{dictionary}|| "default";

    my @params;
    push @params, "wt=json";
    push @params, "suggest=true";
    push @params, "suggest.build=false";
    push @params, "suggest.dictionary=" . uri_escape( $dictionary );
    push @params, "suggest.q=" . uri_escape( $term );

    my $url = $endpoint;
    $url =~ s{/+$}{};
    $url .= "/" . $handler . "?" . join( "&", @params );

    my $ua = LWP::UserAgent->new(
        timeout => $conf->{timeout} || 10,
        agent   => "EPrints-Solr-Plugin/1.0"
    );

    if( my $auth = $conf->{auth} ) {
        $ua->credentials(
            $auth->{hostport},
            $auth->{realm} || "Solr",
            $auth->{username},
            $auth->{password}
        );
    }

    my $res = $ua->get( $url );

    unless( $res->is_success )
    {
        my $error_msg = "Solr suggest failed: " . $res->status_line;
        $repo->log( $error_msg );
        return (undef, $error_msg);
    }

    my $data = eval { decode_json( $res->decoded_content ) };
    if( $@ )
    {
        my $error_msg = "Invalid JSON from Solr suggest: $@";
        $repo->log( $error_msg );
        return (undef, $error_msg);
    }

    return ($data, undef);
}

sub _render_search_form
{
    my( $self ) = @_;
    my $session = $self->{session};

    my $current_q = $self->{processor}->{q} || "*:*";
    $current_q = "" if $current_q eq "*:*";

    my $current_sort = $self->{processor}->{sort} || "score desc";

    my $form = $session->render_form( "get" );
    $form->setAttribute( id => "facetview_search" );
    # we will NOT intercept submit via AJAX (normal full refresh)
    $form->setAttribute( "data-ajax-search", "false" );

    my $perl_url = $session->config( "perl_url" );
    $form->setAttribute( "action", $perl_url . "/users/home" );

    $form->appendChild(
        $session->render_hidden_field( "screen", $self->_screen_id )
    );

    foreach my $fq ( @{$self->{processor}->{fq} || []} )
    {
        $form->appendChild(
            $session->render_hidden_field( "fq", $fq )
        );
    }

    my $div = $session->make_element(
        "div",
        id    => "facetview_searchbox",
        class => "ep_solr_search_box"
    );

    my $label = $session->make_element(
        "label",
        for   => "facetview_freetext",
        class => "facetview_freetext_label"
    );
    $label->appendChild( $session->make_text( "Search" ) );
    $div->appendChild( $label );

    my $input = $session->render_input_field(
        name  => "q",
        id    => "facetview_freetext",
        class => "facetview_freetext ep_form_text",
        value => $current_q,
        size  => 40,
        placeholder => "Enter search terms...",
        "data-autocomplete" => "true"
    );
    $div->appendChild( $input );

    my %allowed_sorts = (
        "score desc"     => "Relevance",
        "year_i desc"    => "Newest first",
        "year_i asc"     => "Oldest first",
        "title_sort asc" => "Title A–Z",
        "title_sort desc"=> "Title Z–A",
    );

    my $sort_label = $session->make_element(
        "label",
        for   => "facetview_sort",
        class => "facetview_sort_label"
    );
    $sort_label->appendChild( $session->make_text( " Sort by " ) );
    $div->appendChild( $sort_label );

    my $sort_select = $session->make_element(
        "select",
        name  => "sort",
        id    => "facetview_sort",
        class => "facetview_sort_select"
    );

    foreach my $sort_key ( "score desc", "year_i desc", "year_i asc", "title_sort asc", "title_sort desc" )
    {
        my $option = $session->make_element( "option", value => $sort_key );
        $option->appendChild( $session->make_text( $allowed_sorts{$sort_key} ) );
        $option->setAttribute( "selected", "selected" ) if $sort_key eq $current_sort;
        $sort_select->appendChild( $option );
    }

    $div->appendChild( $sort_select );

    my $submit = $session->render_button(
        type  => "submit",
        class => "facetview_force_search ep_form_action_button",
        value => "Search",
    );
    $div->appendChild( $session->make_text(" ") );
    $div->appendChild( $submit );

    my $clear_link = $session->render_link(
        $perl_url . "/users/home?screen=" . $self->_screen_id . "&_action=clear"
    );
    $clear_link->setAttribute( class => "facetview_clear" );
    $clear_link->appendChild( $session->make_text("Reset") );
    $div->appendChild( $session->make_text(" ") );
    $div->appendChild( $clear_link );

    my $export_link = $session->render_link(
        $perl_url . "/users/home?screen=" . $self->_screen_id . "&_action=export"
    );
    $export_link->setAttribute( class => "facetview_export" );
    $export_link->appendChild( $session->make_text("Export Results") );
    $div->appendChild( $session->make_text(" ") );
    $div->appendChild( $export_link );

    $form->appendChild( $div );
    return $form;
}

sub _render_results_summary
{
    my( $self, $solr, $page, $rows, $elapsed ) = @_;
    my $session = $self->{session};

    my $resp  = $solr->{response} || {};
    my $total = $resp->{numFound} || 0;
    my $start = $resp->{start} || 0;

    my $end = $start + $rows;
    $end = $total if $end > $total;

    my $summary = $session->make_element(
        "div",
        class => "ep_solr_results_summary"
    );

    my $text = sprintf(
        "Showing %d-%d of %d results (%.2f seconds)",
        $start + 1, $end, $total, $elapsed
    );

    $summary->appendChild( $session->make_text( $text ) );

    return $summary;
}

sub _render_facets
{
    my( $self, $solr, $active_fqs, $query ) = @_;
    my $session = $self->{session};
    my $repo    = $session->get_repository;
    my $conf    = $repo->config( "solr" ) || {};

    my %active = map { $_ => 1 } @$active_fqs;

    my $facets_root = $session->make_element(
        "div",
        id    => "facetview_filters",
        class => "ep_solr_facets"
    );

    my $title = $session->make_element( "h3" );
    $title->appendChild( $session->make_text( "Filter Results" ) );
    $facets_root->appendChild( $title );

    my $fc = $solr->{facet_counts} || {};
    my $ff = $fc->{facet_fields} || {};

    if( @$active_fqs )
    {
        my $active_box = $session->make_element(
            "div",
            class => "ep_solr_active_filters"
        );

        my $h = $session->make_element( "h4" );
        $h->appendChild( $session->make_text( "Active Filters" ) );
        $active_box->appendChild( $h );

        my $ul = $session->make_element( "ul", class => "facetview_active_filters" );

        foreach my $fq ( @$active_fqs )
        {
            my $li = $session->make_element( "li", class => "facetview_active_filter" );

            my $remove_uri = $self->_remove_filter_link( $fq );
            my $remove_link = $session->render_link( $remove_uri );
            $remove_link->setAttribute( class => "facetview_remove_filter" );
            $remove_link->setAttribute( "title", "Remove filter" );
            $remove_link->appendChild( $session->make_text( "×" ) );

            my $filter_text = $session->make_element( "span", class => "filter_text" );
            $filter_text->appendChild( $session->make_text( $self->_pretty_filter_label( $fq ) ) );

            $li->appendChild( $remove_link );
            $li->appendChild( $filter_text );
            $ul->appendChild( $li );
        }

        $active_box->appendChild( $ul );
        $facets_root->appendChild( $active_box );
    }

    foreach my $cfg ( @{$conf->{facets} || []} )
    {
        my $field = $cfg->{field};
        my $label = $cfg->{label} || $field;
        my $data  = $ff->{$field};
        next unless $data && ref($data) eq 'ARRAY';

        my $box = $session->make_element(
            "div",
            class => "ep_solr_facet_box facetview_filter",
            "data-field" => $field
        );

        my $h = $session->make_element( "h4", class => "facetview_filtertitle" );
        $h->appendChild( $session->make_text( $label ) );
        $box->appendChild( $h );

        my $search_div = $session->make_element( "div", class => "facet_search_box" );
        my $search_input = $session->render_input_field(
            type => "text",
            class => "facet_search_input",
            placeholder => "Search " . lc($label),
            "data-facet-field" => $field
        );
        $search_div->appendChild( $search_input );
        $box->appendChild( $search_div );

        # Select box for facet options
        my $select = $session->make_element(
            "select",
            class => "facet_select",
            "data-field" => $field
        );
        my $opt_default = $session->make_element( "option", value => "" );
        $opt_default->appendChild( $session->make_text( "-- Select $label --" ) );
        $select->appendChild( $opt_default );

        my $ul = $session->make_element( "ul", class => "facetview_values" );

        my $total_values    = scalar(@$data) / 2;
        my $values_per_page = $cfg->{values_per_page} || 50;
        my $displayed       = 0;

        for( my $i = 0; $i < @$data && $displayed < $values_per_page; $i += 2 )
        {
            my $val   = $data->[$i];
            my $count = $data->[$i+1];
            next unless defined $val && $count > 0;

            $displayed++;

            my $fq_str = "$field:" . _quote_if_needed( $val );

            # Add to select
            my $opt = $session->make_element( "option", value => $fq_str );
            $opt->appendChild( $session->make_text( "$val ($count)" ) );
            $opt->setAttribute( "selected", "selected" ) if $active{$fq_str};
            $select->appendChild( $opt );

            my $li = $session->make_element( "li", class => "facetview_filtervalue" );


            if( $active{$fq_str} )
            {
                my $span = $session->make_element(
                    "span",
                    class       => "facetview_filterselected",
                    "data-field" => $field,
                    "data-value" => $val,
                );
                $span->appendChild( $session->make_text( "$val" ) );

                my $count_span = $session->make_element( "span", class => "facet_count" );
                $count_span->appendChild( $session->make_text( " ($count)" ) );

               
                $li->appendChild( $span );
                $li->appendChild( $count_span );
            }
            else
            {
                my $uri = $self->_facet_link( $fq_str );
                my $a   = $session->render_link( $uri );
                $a->setAttribute( class => "facetview_filterchoice" );
                $a->setAttribute( "data-field", $field );
                $a->setAttribute( "data-value", $val );
                $a->appendChild( $session->make_text( "$val" ) );

                my $count_span = $session->make_element( "span", class => "facet_count" );
                $count_span->appendChild( $session->make_text( " ($count)" ) );

                
                $li->appendChild( $a );
                $li->appendChild( $count_span );
            }

            $ul->appendChild( $li );
        }

        $box->appendChild( $select );
        $box->appendChild( $ul );

        if( $total_values > 10 )
        {
            my $facet_pager = $session->make_element( "div", class => "facet_pager" );

            my $show_more = $session->make_element(
                "button",
                class => "facet_show_more",
                "data-field" => $field
            );
            $show_more->appendChild( $session->make_text( "Show More" ) );
            $facet_pager->appendChild( $show_more );

            $box->appendChild( $facet_pager );
        }

        $facets_root->appendChild( $box );
    }

    return $facets_root;
}

sub _pretty_filter_label
{
    my( $self, $fq ) = @_;

    if( $fq =~ /^([^:]+):(.+)$/ )
    {
        my( $field, $value ) = ( $1, $2 );
        $value =~ s/^"(.+)"$/$1/;
        $field =~ s/_/ /g;
        $field = ucfirst( $field );
        return "$field: $value";
    }

    return $fq;
}

sub _remove_filter_link
{
    my( $self, $remove_fq ) = @_;
    my $session = $self->{session};

    my $q    = $self->{processor}->{q} || "*:*";
    my $page = 1;
    my @fqs  = grep { $_ ne $remove_fq } @{$self->{processor}->{fq} || []};

    my %params = (
        screen => $self->_screen_id,
        q      => $q,
        page   => $page,
        sort   => $self->{processor}->{sort} || "score desc",
    );

    my @pairs;
    foreach my $k ( keys %params )
    {
        push @pairs, $k . "=" . uri_escape( $params{$k} ) if defined $params{$k};
    }
    foreach my $fq ( @fqs )
    {
        push @pairs, "fq=" . uri_escape( $fq );
    }

    my $base = $session->config( "perl_url" ) . "/users/home";
    return $base . "?" . join( "&", @pairs );
}

sub _facet_link
{
    my( $self, $new_fq ) = @_;
    my $session = $self->{session};

    my $q    = $self->{processor}->{q} || "*:*";
    my $page = 1;
    my @fqs  = @{$self->{processor}->{fq} || []};

    push @fqs, $new_fq;

    my %params = (
        screen => $self->_screen_id,
        q      => $q,
        page   => $page,
        sort   => $self->{processor}->{sort} || "score desc",
    );

    my @pairs;
    foreach my $k ( keys %params )
    {
        push @pairs, $k . "=" . uri_escape( $params{$k} ) if defined $params{$k};
    }
    foreach my $fq ( @fqs )
    {
        push @pairs, "fq=" . uri_escape( $fq );
    }

    my $base = $session->config( "perl_url" ) . "/users/home";
    return $base . "?" . join( "&", @pairs );
}

sub _render_results
{
    my( $self, $solr, $q, $fqs, $page, $rows, $sort ) = @_;
    my $session  = $self->{session};
    my $repo     = $session->get_repository;
    my $conf     = $repo->config( "solr" ) || {};
    my $id_field = $conf->{id_field} || "eprintid_i";

    my $resp  = $solr->{response} || {};
    my $total = $resp->{numFound} || 0;
    my $docs  = $resp->{docs} || [];
    my $hl    = $solr->{highlighting} || {};

    my $wrap = $session->make_element(
        "div",
        class => "ep_solr_results"
    );

    my $ds = $repo->dataset( "archive" );

    my $results_container = $session->make_element(
        "div",
        id    => "facetview_results",
        class => "ep_solr_results_list"
    );

    if( $total == 0 )
    {
        my $no_results = $session->make_element(
            "div",
            class => "ep_solr_no_results"
        );
        $no_results->appendChild( $session->make_text( "No results found. Try different search terms or remove some filters." ) );
        $results_container->appendChild( $no_results );
        $wrap->appendChild( $results_container );
        return $wrap;
    }

    my $ul = $session->make_element(
        "ul",
        class => "ep_search_results"
    );

    foreach my $doc ( @$docs )
    {
        my $id = $doc->{$id_field};
        next unless defined $id;

        my $ep = $ds->dataobj( $id );
        next unless defined $ep;

        my $li = $session->make_element( "li", class => "ep_solr_result_item" );

        if( my $highlight = $hl->{$id} )
        {
            my $snippets = $session->make_element( "div", class => "ep_solr_highlights" );

            foreach my $field ( sort keys %$highlight )
            {
                foreach my $snippet ( @{$highlight->{$field}} )
                {
                    my $snippet_div = $session->make_element( "div", class => "ep_solr_snippet" );

                    my $html = "... $snippet ...";
                    my $frag = EPrints::XML::parse_xhtml(
                        $session->get_repository,
                        $html
                    );

                    $snippet_div->appendChild( $frag );
                    $snippets->appendChild( $snippet_div );
                }
            }
            $li->appendChild( $snippets );
        }

        $li->appendChild( $ep->render_citation( "default" ) );
        $ul->appendChild( $li );
    }

    $results_container->appendChild( $ul );
    $wrap->appendChild( $results_container );

    my $pager_dom = $self->_render_pager( $total, $page, $rows );
    if( defined $pager_dom )
    {
        my $meta = $session->make_element(
            "div",
            class => "facetview_metadata ep_solr_pagerwrap"
        );
        $meta->appendChild( $pager_dom );
        $wrap->appendChild( $meta );
    }

    return $wrap;
}

sub _render_pager
{
    my( $self, $total, $current_page, $rows ) = @_;
    my $session = $self->{session};

    return undef if $total <= $rows;

    # Ensure $current_page is properly initialized and numeric
    $current_page = 1 if !defined $current_page || $current_page !~ /^\d+$/ || $current_page < 1;
    
    my $max_page = int( ($total + $rows - 1) / $rows );
    $current_page = $max_page if $current_page > $max_page;

    my $container = $session->make_element(
        "div",
        class => "ep_solr_pager"
    );

    if( $current_page > 1 ) {
        my $prev_uri = $self->_page_link( $current_page - 1 );
        my $prev_link = $session->render_link( $prev_uri );
        $prev_link->setAttribute( class => "ep_solr_page_prev" );
        $prev_link->appendChild( $session->make_text( "‹ Previous" ) );
        $container->appendChild( $prev_link );
        $container->appendChild( $session->make_text( " " ) );
    }

    my $start_page = max( 1, $current_page - 2 );
    my $end_page   = min( $max_page, $current_page + 2 );

    if( $start_page > 1 ) {
        $container->appendChild( $self->_make_page_link( 1 ) );
        if( $start_page > 2 ) {
            my $ellipsis = $session->make_element( "span", class => "ep_solr_page_ellipsis" );
            $ellipsis->appendChild( $session->make_text( "..." ) );
            $container->appendChild( $ellipsis );
        }
    }

    for my $p ( $start_page .. $end_page )
    {
        $container->appendChild( $self->_make_page_link( $p, $current_page ) );
    }

    if( $end_page < $max_page ) {
        if( $end_page < $max_page - 1 ) {
            my $ellipsis = $session->make_element( "span", class => "ep_solr_page_ellipsis" );
            $ellipsis->appendChild( $session->make_text( "..." ) );
            $container->appendChild( $ellipsis );
        }
        $container->appendChild( $self->_make_page_link( $max_page ) );
    }

    if( $current_page < $max_page ) {
        $container->appendChild( $session->make_text( " " ) );
        my $next_uri = $self->_page_link( $current_page + 1 );
        my $next_link = $session->render_link( $next_uri );
        $next_link->setAttribute( class => "ep_solr_page_next" );
        $next_link->appendChild( $session->make_text( "Next ›" ) );
        $container->appendChild( $next_link );
    }

    return $container;
}

sub _make_page_link
{
    my( $self, $p, $current_page ) = @_;
    my $session = $self->{session};

    my $node;
    if( defined $current_page && $p == $current_page )
    {
        $node = $session->make_element(
            "span",
            class => "ep_solr_page_current"
        );
        $node->appendChild( $session->make_text( $p ) );
    }
    else
    {
        my $uri = $self->_page_link( $p );
        $node = $session->render_link( $uri );
        $node->setAttribute( class => "ep_solr_page_link" );
        $node->appendChild( $session->make_text( $p ) );
    }
    $node->appendChild( $session->make_text( " " ) );
    return $node;
}

sub _page_link
{
    my( $self, $page ) = @_;
    my $session = $self->{session};

    my $q   = $self->{processor}->{q} || "*:*";
    my @fqs = @{$self->{processor}->{fq} || []};

    my %params = (
        screen => $self->_screen_id,
        q      => $q,
        page   => $page,
        sort   => $self->{processor}->{sort} || "score desc",
    );

    my @pairs;
    foreach my $k ( keys %params )
    {
        push @pairs, $k . "=" . uri_escape( $params{$k} ) if defined $params{$k};
    }
    foreach my $fq ( @fqs )
    {
        push @pairs, "fq=" . uri_escape( $fq );
    }

    my $base = $session->config( "perl_url" ) . "/users/home";
    return $base . "?" . join( "&", @pairs );
}

sub _export_results
{
    my( $self, $solr ) = @_;
    my $session = $self->{session};
    my $repo    = $session->get_repository;

    my $docs = $solr->{response}->{docs} || [];
    my $ds   = $repo->dataset( "archive" );

    # Set filename for download
    my $filename = "search_results_" . time() . ".csv";
    
    $session->get_http->send_http_header( "text/csv; charset=utf-8" );
    $session->get_http->header( "Content-Disposition: attachment; filename=\"$filename\"" );
    binmode STDOUT, ":utf8";

    print "ID,Title,Authors,Year,Type,URL\n";

    foreach my $doc ( @$docs )
    {
        my $id = $doc->{eprintid_i};
        next unless $id;

        my $ep = $ds->dataobj( $id );
        next unless $ep;

        my $title = $ep->get_value( "title" ) || "";
        $title =~ s/"/""/g;

        my $creators = $ep->get_value( "creators" ) || [];
        my @author_names;

        foreach my $c ( @$creators )
        {
            my $name = $c->{name};
            next unless $name;
            my $formatted = EPrints::Utils::make_name_string( $name );
            push @author_names, $formatted if defined $formatted && $formatted ne "";
        }

        my $authors = join( "; ", @author_names );
        $authors =~ s/"/""/g;

        my $year = $ep->get_value( "date" ) || $ep->get_value( "year" ) || "";
        if( $year && $year =~ /^(\d{4})/ )
        {
            $year = $1;
        }

        my $type = $ep->get_value( "type" ) || "";
        $type =~ s/"/""/g;

        my $url = $ep->get_url() || "";
        $url =~ s/"/""/g;

        print qq{"$id","$title","$authors","$year","$type","$url"\n};
    }

    exit;
}

sub _screen_id
{
    return "SolrFacetedBrowse";
}

sub _quote_if_needed
{
    my( $val ) = @_;
    if( $val =~ /\s/ || $val =~ /[:()]/ )
    {
        $val =~ s/"/\\"/g;
        return "\"$val\"";
    }
    return $val;
}

sub max { $_[0] > $_[1] ? $_[0] : $_[1] }
sub min { $_[0] < $_[1] ? $_[0] : $_[1] }

1;
