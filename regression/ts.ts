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

// Complicated TypeScript example exercising TS Handbook functional constructs:
// - Type aliases & Interface declarations
// - Generic functions <T>
// - Union type annotations
// - typeof type narrowing
// - Floating point calculations
// - Array & Object processing
// - Template string interpolation
// - Try/Catch exception handling

type ScoreList = number[];

interface ProcessResult {
  count: number;
  total: number;
  avg: number;
  max: number;
  label: string;
  status: number;
  summary: string;
};

function identity<T>(arg: T): T {
  return arg;
};

function classify_value(val: string | number): string {
  if (typeof val === "string") {
    return `text:${val}`;
  } else {
    return `num:${val}`;
  };
};

function process_scores(scores: ScoreList, threshold: number): ProcessResult {
  let count: number = 0;
  let total: number = 0.0;
  let max_val: number = -1.0;

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

  let avg: number = 0.0;
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

  let tag: string = classify_value(identity("valid"));

  return {
    count: count,
    total: total,
    avg: avg,
    max: max_val,
    label: label,
    status: safe_check,
    summary: tag
  };
};

let scores: ScoreList = [10.5, 25.5, 40.0, 15.0, 50.0];
let stats: ProcessResult = process_scores(scores, 20.0);

// Return result object for Mudlle validation
stats;
