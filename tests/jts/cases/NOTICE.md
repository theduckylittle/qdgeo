# Third-party test data

The `.xml` files in this directory are test cases from the **JTS Topology
Suite**, copied unmodified from
`modules/tests/src/test/resources/testxml/general/` in
<https://github.com/locationtech/jts>.

They are **not** qdgeo's code and carry no qdgeo copyright. JTS is
Copyright (c) Eclipse Foundation and contributors, dual-licensed under:

- Eclipse Public License 2.0 (`EPL-2.0`), and
- Eclipse Distribution License 1.0 (`EDL-1.0`), a BSD-style licence.

These files are redistributed here under the **EDL-1.0**. See
<https://www.eclipse.org/org/documents/edl-v10.php>.

## Which files, and why these

| File | Covers |
| --- | --- |
| `TestOverlayAA.xml` | Area-area overlay: intersection, union, difference, symmetric difference |
| `TestNGOverlayA.xml` | The same, against JTS's newer OverlayNG engine |
| `TestBuffer.xml` | Buffer over points, lines and polygons, positive and negative |

The rest of the JTS suite is out of scope for qdgeo by design (goal 3):
`Test*Prec.xml` needs a fixed precision model, which qdgeo rejects outright;
`TestOverlayLA/LL/PA/PL/PP.xml` produce non-areal output; and predicates,
relate, centroid, convex hull and the rest are operations qdgeo does not have.

To refresh, re-copy the files from upstream — they are used verbatim so that
"passes the JTS suite" means the actual JTS suite.
