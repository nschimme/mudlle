/*
 * Copyright (c) 2026 Nils Schimmelmann
 * All rights reserved.
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose, without fee, and without written agreement is hereby granted,
 * provided that the above copyright notice and the following two paragraphs
 * appear in all copies of this software and its documentation.
 *
 * IN NO EVENT SHALL NILS SCHIMMELMANN BE LIABLE TO ANY PARTY FOR DIRECT,
 * INDIRECT, INCIDENTAL, OR CONSEQUENTIAL DAMAGES ARISING OUT OF THE USE OF
 * THIS SOFTWARE AND ITS DOCUMENTATION, EVEN IF NILS SCHIMMELMANN HAS BEEN
 * ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 * NILS SCHIMMELMANN SPECIFICALLY DISCLAIMS ANY WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
 * PARTICULAR PURPOSE. THE SOFTWARE PROVIDED HEREUNDER IS ON AN "AS IS" BASIS,
 * AND NILS SCHIMMELMANN HAS NO OBLIGATION TO PROVIDE MAINTENANCE, SUPPORT,
 * UPDATES, ENHANCEMENTS, OR MODIFICATIONS.
 */

if (!load("regression/benchmark-numeric.mud")
    || !load("regression/benchmark-sequences.mud")
    || !load("regression/benchmark-tables.mud")) quit(1);
display("benchmark-rich-success\n");
