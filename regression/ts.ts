/*
 * Copyright (c) 2026 Nils Schimmelmann
 * All rights reserved.
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose, without fee, and without written agreement is hereby granted,
 * provided that the above copyright notice and the following two paragraphs
 * appear in all copies of this software.
 *
 * IN NO EVENT SHALL NILS SCHIMMELMANN BE LIABLE TO ANY PARTY FOR DIRECT,
 * INDIRECT, SPECIAL, INCIDENTAL, OR CONSEQUENTIAL DAMAGES ARISING OUT OF THE
 * USE OF THIS SOFTWARE AND ITS DOCUMENTATION, EVEN IF NILS SCHIMMELMANN HAS
 * BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 * NILS SCHIMMELMANN SPECIFICALLY DISCLAIMS ANY WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
 * PARTICULAR PURPOSE.  THE SOFTWARE PROVIDED HEREUNDER IS ON AN "AS IS"
 * BASIS, AND NILS SCHIMMELMANN HAS NO OBLIGATION TO PROVIDE MAINTENANCE,
 * SUPPORT, UPDATES, ENHANCEMENTS, OR MODIFICATIONS.
 */

// Complicated TypeScript example exercising TS features and Mudlle interop

function process_scores(scores: vector, threshold: number): object {
  let count: number = 0;
  let total: number = 0;
  let max_val: number = -1;

  for (let i: number = 0; i < 5; i = i + 1) {
    let val: number = scores[i];
    if (val >= threshold) {
      count = count + 1;
      total = total + val;
      if (val > max_val) {
        max_val = val;
      };
    };
  };

  let avg: number = 0;
  if (count > 0) {
    avg = total / count;
  };

  let label: string = `Count: ${count}, Avg: ${avg}, Max: ${max_val}`;

  let safe_check: number = 0;
  try {
    if (threshold < 0) {
      throw 404;
    } else {
      safe_check = 200;
    };
  } catch (err) {
    safe_check = 500;
  };

  return {
    count: count,
    total: total,
    avg: avg,
    max: max_val,
    label: label,
    status: safe_check
  };
};

let scores: vector = [10, 25, 40, 15, 50];
let stats: object = process_scores(scores, 20);

// Return result object for Mudlle validation
stats;
