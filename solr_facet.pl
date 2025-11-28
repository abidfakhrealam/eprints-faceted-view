$c->{solr} = {
    endpoint => 'http://localhost:8983/solr/eprints',  # adjust
    rows     => 20,
    facet_limit => 50,
    timeout  => 30,
    id_field => 'eprintid_i',

    facets => [
        { field => 'year_i',       label => 'Year',         values_per_page => 50 },
        { field => 'type_s',       label => 'Item type',    values_per_page => 50 },
        { field => 'subjects_ss',  label => 'Subjects',     values_per_page => 50 },
		    { field => 'subject_name_name',  label => 'New Subjects',     values_per_page => 50 },
        # ...
    ],

    suggest => {
        handler    => 'suggest',    # e.g. /solr/eprints/suggest
        dictionary => 'default',    # must match your solrconfig.xml
    },

    export_rows => 1000,
};
