use strict;
use warnings;

use Test::More;
use lib qw(t/lib);
use DBICTest;
use B::Deparse;

# globally set for the rest of test
# the rowparser maker does not order its hashes by default for the miniscule
# speed gain. But it does not disable sorting either - for this test
# everything will be ordered nicely, and the hash randomization of 5.18
# will not trip up anything
use Data::Dumper;
$Data::Dumper::Sortkeys = 1;

my $schema = DBICTest->init_schema(no_deploy => 1);
my $infmap = [qw/single_track.cd.artist.name year/];

is_same_src (
  $schema->source ('CD')->_mk_row_parser({
    inflate_map => $infmap,
  }),
  '$_ = [
    { year => $_->[1] },
    { single_track => [
      undef,
      { cd => [
        undef,
        { artist => [
          { name  => $_->[0] },
        ] },
      ]},
    ]},
  ] for @{$_[0]}',
  'Simple 1:1 descending non-collapsing parser',
);

$infmap = [qw/
  single_track.cd.artist.cds.tracks.title
  single_track.cd.artist.artistid
  year
  single_track.cd.artist.cds.cdid
  title
  artist
/];
is_same_src (
  $schema->source ('CD')->_mk_row_parser({
    inflate_map => $infmap,
  }),
  '$_ = [
    { artist => $_->[5], title => $_->[4], year => $_->[2] },
    { single_track => [
      undef,
      { cd => [
        undef,
        { artist => [
          { artistid => $_->[1] },
          { cds => [
            { cdid => $_->[3] },
            { tracks => [
              { title => $_->[0] }
            ] },
          ] },
        ] },
      ] },
    ] },
  ] for @{$_[0]}',
  '1:1 descending non-collapsing parser terminating with chained 1:M:M',
);

is_deeply (
  ($schema->source('CD')->_resolve_collapse({ as => {map { $infmap->[$_] => $_ } 0 .. $#$infmap} })),
  {
    -node_index => 1,
    -idcols_current_node => [ 4, 5 ],
    -idcols_extra_from_children => [ 0, 3 ],

    single_track => {
      -node_index => 2,
      -idcols_current_node => [ 4, 5 ],
      -idcols_extra_from_children => [ 0, 3 ],
      -is_optional => 1,
      -is_single => 1,

      cd => {
        -node_index => 3,
        -idcols_current_node => [ 4, 5 ],
        -idcols_extra_from_children => [ 0, 3 ],
        -is_single => 1,

        artist => {
          -node_index => 4,
          -idcols_current_node => [ 4, 5 ],
          -idcols_extra_from_children => [ 0, 3 ],
          -is_single => 1,

          cds => {
            -node_index => 5,
            -idcols_current_node => [ 3, 4, 5 ],
            -idcols_extra_from_children => [ 0 ],
            -is_optional => 1,

            tracks => {
              -node_index => 6,
              -idcols_current_node => [ 0, 3, 4, 5 ],
              -is_optional => 1,
            },
          },
        },
      },
    },
  },
  'Correct collapse map for 1:1 descending chain terminating with chained 1:M:M'
);

is_same_src (
  $schema->source ('CD')->_mk_row_parser({
    inflate_map => $infmap,
    collapse => 1,
  }),
  ' my($rows_pos, $result_pos, $cur_row, @cur_row_ids, @collapse_idx, $is_new_res) = (0, 0);

    while ($cur_row = (
      ( $rows_pos >= 0 and $_[0][$rows_pos++] ) or do { $rows_pos = -1; undef } )
        ||
      ( $_[1] and $_[1]->() )
    ) {

      $cur_row_ids[$_] = defined $cur_row->[$_] ? $cur_row->[$_] : "\0NULL\xFF$rows_pos\xFF$_\0"
        for (0, 3, 4, 5);

      # a present cref in $_[1] implies lazy prefetch, implies a supplied stash in $_[2]
      $_[1] and $result_pos and unshift(@{$_[2]}, $cur_row) and last
        if $is_new_res = ! $collapse_idx[1]{$cur_row_ids[4]}{$cur_row_ids[5]};

      # the rowdata itself for root node
      $collapse_idx[1]{$cur_row_ids[4]}{$cur_row_ids[5]} ||= [{ artist => $cur_row->[5], title => $cur_row->[4], year => $cur_row->[2] }];

      # prefetch data of single_track (placed in root)
      $collapse_idx[1]{$cur_row_ids[4]}{$cur_row_ids[5]}[1]{single_track} ||= $collapse_idx[2]{$cur_row_ids[4]}{$cur_row_ids[5]};

      # prefetch data of cd (placed in single_track)
      $collapse_idx[2]{$cur_row_ids[4]}{$cur_row_ids[5]}[1]{cd} ||= $collapse_idx[3]{$cur_row_ids[4]}{$cur_row_ids[5]};

      # prefetch data of artist ( placed in single_track->cd)
      $collapse_idx[3]{$cur_row_ids[4]}{$cur_row_ids[5]}[1]{artist} ||= $collapse_idx[4]{$cur_row_ids[4]}{$cur_row_ids[5]} ||= [{ artistid => $cur_row->[1] }];

      # prefetch data of cds (if available)
      push @{$collapse_idx[4]{$cur_row_ids[4]}{$cur_row_ids[5]}[1]{cds}}, $collapse_idx[5]{$cur_row_ids[3]}{$cur_row_ids[4]}{$cur_row_ids[5]} ||= [{ cdid => $cur_row->[3] }]
        unless $collapse_idx[5]{$cur_row_ids[3]}{$cur_row_ids[4]}{$cur_row_ids[5]};

      # prefetch data of tracks (if available)
      push @{$collapse_idx[5]{$cur_row_ids[3]}{$cur_row_ids[4]}{$cur_row_ids[5]}[1]{tracks}}, $collapse_idx[6]{$cur_row_ids[0]}{$cur_row_ids[3]}{$cur_row_ids[4]}{$cur_row_ids[5]} ||= [{ title => $cur_row->[0] }]
        unless $collapse_idx[6]{$cur_row_ids[0]}{$cur_row_ids[3]}{$cur_row_ids[4]}{$cur_row_ids[5]};

      $_[0][$result_pos++] = $collapse_idx[1]{$cur_row_ids[4]}{$cur_row_ids[5]}
        if $is_new_res;
    }
    splice @{$_[0]}, $result_pos;
  ',
  'Same 1:1 descending terminating with chained 1:M:M but with collapse',
);

$infmap = [qw/
  tracks.lyrics.lyric_versions.text
  existing_single_track.cd.artist.artistid
  existing_single_track.cd.artist.cds.year
  year
  genreid
  tracks.title
  existing_single_track.cd.artist.cds.cdid
  latest_cd
  existing_single_track.cd.artist.cds.tracks.title
  existing_single_track.cd.artist.cds.genreid
/];

is_deeply (
  $schema->source('CD')->_resolve_collapse({ as => {map { $infmap->[$_] => $_ } 0 .. $#$infmap} }),
  {
    -node_index => 1,
    -idcols_current_node => [ 1 ], # existing_single_track.cd.artist.artistid
    -idcols_extra_from_children => [ 0, 5, 6, 8 ],

    existing_single_track => {
      -node_index => 2,
      -idcols_current_node => [ 1 ], # existing_single_track.cd.artist.artistid
      -idcols_extra_from_children => [ 6, 8 ],
      -is_single => 1,

      cd => {
        -node_index => 3,
        -idcols_current_node => [ 1 ], # existing_single_track.cd.artist.artistid
        -idcols_extra_from_children => [ 6, 8 ],
        -is_single => 1,

        artist => {
          -node_index => 4,
          -idcols_current_node => [ 1 ], # existing_single_track.cd.artist.artistid
          -idcols_extra_from_children => [ 6, 8 ],
          -is_single => 1,

          cds => {
            -node_index => 5,
            -idcols_current_node => [ 1, 6 ], # existing_single_track.cd.artist.cds.cdid
            -idcols_extra_from_children => [ 8 ],
            -is_optional => 1,

            tracks => {
              -node_index => 6,
              -idcols_current_node => [ 1, 6, 8 ], # existing_single_track.cd.artist.cds.cdid, existing_single_track.cd.artist.cds.tracks.title
              -is_optional => 1,
            }
          }
        }
      }
    },
    tracks => {
      -node_index => 7,
      -idcols_current_node => [ 1, 5 ], # existing_single_track.cd.artist.artistid, tracks.title
      -idcols_extra_from_children => [ 0 ],
      -is_optional => 1,

      lyrics => {
        -node_index => 8,
        -idcols_current_node => [ 1, 5 ], # existing_single_track.cd.artist.artistid, tracks.title
        -idcols_extra_from_children => [ 0 ],
        -is_single => 1,
        -is_optional => 1,

        lyric_versions => {
          -node_index => 9,
          -idcols_current_node => [ 0, 1, 5 ], # tracks.lyrics.lyric_versions.text, existing_single_track.cd.artist.artistid, tracks.title
          -is_optional => 1,
        },
      },
    }
  },
  'Correct collapse map constructed',
);

is_same_src (
  $schema->source ('CD')->_mk_row_parser({
    inflate_map => $infmap,
    collapse => 1,
  }),
  ' my ($rows_pos, $result_pos, $cur_row, @cur_row_ids, @collapse_idx, $is_new_res) = (0,0);

    while ($cur_row = (
      ( $rows_pos >= 0 and $_[0][$rows_pos++] ) or do { $rows_pos = -1; undef } )
        ||
      ( $_[1] and $_[1]->() )
    ) {

      $cur_row_ids[$_] = defined $cur_row->[$_] ? $cur_row->[$_] : "\0NULL\xFF$rows_pos\xFF$_\0"
        for (0, 1, 5, 6, 8);

      $is_new_res = ! $collapse_idx[1]{$cur_row_ids[1]} and (
        $_[1] and $result_pos and (unshift @{$_[2]}, $cur_row) and last
      );

      $collapse_idx[1]{$cur_row_ids[1]} ||= [{ genreid => $cur_row->[4], latest_cd => $cur_row->[7], year => $cur_row->[3] }];

      $collapse_idx[1]{$cur_row_ids[1]}[1]{existing_single_track} ||= $collapse_idx[2]{$cur_row_ids[1]};
      $collapse_idx[2]{$cur_row_ids[1]}[1]{cd} ||= $collapse_idx[3]{$cur_row_ids[1]};
      $collapse_idx[3]{$cur_row_ids[1]}[1]{artist} ||= $collapse_idx[4]{$cur_row_ids[1]} ||= [{ artistid => $cur_row->[1] }];

      push @{ $collapse_idx[4]{$cur_row_ids[1]}[1]{cds} }, $collapse_idx[5]{$cur_row_ids[1]}{$cur_row_ids[6]} ||= [{ cdid => $cur_row->[6], genreid => $cur_row->[9], year => $cur_row->[2] }]
        unless $collapse_idx[5]{$cur_row_ids[1]}{$cur_row_ids[6]};

      push @{ $collapse_idx[5]{$cur_row_ids[1]}{$cur_row_ids[6]}[1]{tracks} }, $collapse_idx[6]{$cur_row_ids[1]}{$cur_row_ids[6]}{$cur_row_ids[8]} ||= [{ title => $cur_row->[8] }]
        unless $collapse_idx[6]{$cur_row_ids[1]}{$cur_row_ids[6]}{$cur_row_ids[8]};

      push @{ $collapse_idx[1]{$cur_row_ids[1]}[1]{tracks} }, $collapse_idx[7]{$cur_row_ids[1]}{$cur_row_ids[5]} ||= [{ title => $cur_row->[5] }]
        unless $collapse_idx[7]{$cur_row_ids[1]}{$cur_row_ids[5]};

      $collapse_idx[7]{$cur_row_ids[1]}{$cur_row_ids[5]}[1]{lyrics} ||= $collapse_idx[8]{$cur_row_ids[1]}{$cur_row_ids[5] };

      push @{ $collapse_idx[8]{$cur_row_ids[1]}{$cur_row_ids[5]}[1]{lyric_versions} }, $collapse_idx[9]{$cur_row_ids[0]}{$cur_row_ids[1]}{$cur_row_ids[5]} ||= [{ text => $cur_row->[0] }]
        unless $collapse_idx[9]{$cur_row_ids[0]}{$cur_row_ids[1]}{$cur_row_ids[5]};

      $_[0][$result_pos++] = $collapse_idx[1]{$cur_row_ids[1]}
        if $is_new_res;
    }

    splice @{$_[0]}, $result_pos;
  ',
  'Multiple has_many on multiple branches torture test',
);

$infmap = [
  'single_track.trackid',                   # (0) definitive link to root from 1:1:1:1:M:M chain
  'year',                                   # (1) non-unique
  'tracks.cd',                              # (2) \ together both uniqueness for second multirel
  'tracks.title',                           # (3) / and definitive link back to root
  'single_track.cd.artist.cds.cdid',        # (4) to give uniquiness to ...tracks.title below
  'single_track.cd.artist.cds.year',        # (5) non-unique
  'single_track.cd.artist.artistid',        # (6) uniqufies entire parental chain
  'single_track.cd.artist.cds.genreid',     # (7) nullable
  'single_track.cd.artist.cds.tracks.title',# (8) unique when combined with ...cds.cdid above
];

is_deeply (
  $schema->source('CD')->_resolve_collapse({ as => {map { $infmap->[$_] => $_ } 0 .. $#$infmap} }),
  {
    -idcols_current_node => [],
    -idcols_extra_from_children => [ 0, 2, 3, 4, 8 ],
    -node_index => 1,
    -root_node_idcol_variants => [
      [ 0 ], [ 2 ],
    ],
    single_track => {
      -idcols_current_node => [ 0 ],
      -idcols_extra_from_children => [ 4, 8 ],
      -is_optional => 1,
      -is_single => 1,
      -node_index => 2,
      cd => {
        -idcols_current_node => [ 0 ],
        -idcols_extra_from_children => [ 4, 8 ],
        -is_single => 1,
        -node_index => 3,
        artist => {
          -idcols_current_node => [ 0 ],
          -idcols_extra_from_children => [ 4, 8 ],
          -is_single => 1,
          -node_index => 4,
          cds => {
            -idcols_current_node => [ 0, 4 ],
            -idcols_extra_from_children => [ 8 ],
            -is_optional => 1,
            -node_index => 5,
            tracks => {
              -idcols_current_node => [ 0, 4, 8 ],
              -is_optional => 1,
              -node_index => 6,
            }
          }
        }
      }
    },
    tracks => {
      -idcols_current_node => [ 2, 3 ],
      -is_optional => 1,
      -node_index => 7,
    }
  },
  'Correct underdefined root collapse map constructed'
);

is_same_src (
  $schema->source ('CD')->_mk_row_parser({
    inflate_map => $infmap,
    collapse => 1,
  }),
  ' my($rows_pos, $result_pos, $cur_row, @cur_row_ids, @collapse_idx, $is_new_res) = (0, 0);

    while ($cur_row = (
      ( $rows_pos >= 0 and $_[0][$rows_pos++] ) or do { $rows_pos = -1; undef } )
        ||
      ( $_[1] and $_[1]->() )
    ) {

      $cur_row_ids[$_] = defined $$cur_row[$_] ? $$cur_row[$_] : "\0NULL\xFF$rows_pos\xFF$_\0"
        for (0, 2, 3, 4, 8);

      # cache expensive set of ops in a non-existent rowid slot
      $cur_row_ids[9] = (
        ( ( defined $cur_row->[0] ) && (join "\xFF", q{}, $cur_row->[0], q{} ))
          or
        ( ( defined $cur_row->[2] ) && (join "\xFF", q{}, $cur_row->[2], q{} ))
          or
        "\0$rows_pos\0"
      );

      $is_new_res = ! $collapse_idx[1]{$cur_row_ids[9]} and (
        $_[1] and $result_pos and (unshift @{$_[2]}, $cur_row) and last
      );

      $collapse_idx[1]{$cur_row_ids[9]} ||= [{ year => $$cur_row[1] }];

      $collapse_idx[1]{$cur_row_ids[9]}[1]{single_track} ||= ($collapse_idx[2]{$cur_row_ids[0]} ||= [{ trackid => $$cur_row[0] }]);

      $collapse_idx[2]{$cur_row_ids[0]}[1]{cd} ||= $collapse_idx[3]{$cur_row_ids[0]};

      $collapse_idx[3]{$cur_row_ids[0]}[1]{artist} ||= ($collapse_idx[4]{$cur_row_ids[0]} ||= [{ artistid => $$cur_row[6] }]);

      push @{$collapse_idx[4]{$cur_row_ids[0]}[1]{cds}},
          $collapse_idx[5]{$cur_row_ids[0]}{$cur_row_ids[4]} ||= [{ cdid => $$cur_row[4], genreid => $$cur_row[7], year => $$cur_row[5] }]
        unless $collapse_idx[5]{$cur_row_ids[0]}{$cur_row_ids[4]};

      push @{$collapse_idx[5]{$cur_row_ids[0]}{$cur_row_ids[4]}[1]{tracks}},
          $collapse_idx[6]{$cur_row_ids[0]}{$cur_row_ids[4]}{$cur_row_ids[8]} ||= [{ title => $$cur_row[8] }]
        unless $collapse_idx[6]{$cur_row_ids[0]}{$cur_row_ids[4]}{$cur_row_ids[8]};

      push @{$collapse_idx[1]{$cur_row_ids[9]}[1]{tracks}},
          $collapse_idx[7]{$cur_row_ids[2]}{$cur_row_ids[3]} ||= [{ cd => $$cur_row[2], title => $$cur_row[3] }]
        unless $collapse_idx[7]{$cur_row_ids[2]}{$cur_row_ids[3]};

      $_[0][$result_pos++] = $collapse_idx[1]{$cur_row_ids[9]}
        if $is_new_res;
    }

    splice @{$_[0]}, $result_pos;
  ',
  'Multiple has_many on multiple branches with underdefined root torture test',
);

done_testing;

my $deparser;
sub is_same_src {
  $deparser ||= B::Deparse->new;
  local $Test::Builder::Level = $Test::Builder::Level + 1;

  my ($got, $expect) = map {
    my $cref = eval "sub { $_ }" or do {
      fail "Coderef does not compile!\n\n$@\n\n$_";
      return undef;
    };
    $deparser->coderef2text($cref);
  } @_[0,1];

  is ($got, $expect, $_[2]||() )
    or note ("Originals source:\n\n$_[0]\n\n$_[1]\n");
}
