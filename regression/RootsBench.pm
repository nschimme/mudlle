# Copyright (c) 2026 Nils Schimmelmann
# All rights reserved.
#
# Permission to use, copy, modify, and distribute this software for any
# purpose, without fee, and without written agreement is hereby granted,
# provided that the above copyright notice and the following two paragraphs
# appear in all copies of this software.
#
# IN NO EVENT SHALL NILS SCHIMMELMANN BE LIABLE TO ANY PARTY FOR DIRECT,
# INDIRECT, INCIDENTAL, SPECIAL, OR CONSEQUENTIAL DAMAGES ARISING OUT OF THE
# USE OF THIS SOFTWARE AND ITS DOCUMENTATION, EVEN IF NILS SCHIMMELMANN HAS
# BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#
# NILS SCHIMMELMANN SPECIFICALLY DISCLAIMS ANY WARRANTIES, INCLUDING, BUT NOT
# LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
# PARTICULAR PURPOSE. THE SOFTWARE PROVIDED HEREUNDER IS ON AN "AS IS" BASIS,
# AND NILS SCHIMMELMANN HAS NO OBLIGATION TO PROVIDE MAINTENANCE, SUPPORT,
# UPDATES, ENHANCEMENTS, OR MODIFICATIONS.

package RootsBench;

use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(identity_probe_source);

sub identity_probe_source {
    my ($source) = @_;
    my @roots = qw(a b c d e f g h j k l m o p q r);
    my %ordinal;
    @ordinal{@roots} = (1 .. @roots);
    $source =~ s/\b(a|b|c|d|e|f|g|h|j|k|l|m|o|p|q|r)\[0\]/'(if (' . $1 . ' == null) 0 else ' . $ordinal{$1} . ')'/ge;
    return $source;
}

1;
