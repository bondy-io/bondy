/*
 * SPDX-FileCopyrightText: 2023 - 2026 Leapsight
 * SPDX-License-Identifier: Apache-2.0
 */

package io.leapsight.jepsen;

/** Server returned 503 — apply/await_apply timed out on the node. */
public class BondyTimeoutException extends RuntimeException {
  public BondyTimeoutException() {
    super();
  }
}
