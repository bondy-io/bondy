/*
 * SPDX-FileCopyrightText: 2023 - 2026 Leapsight
 * SPDX-License-Identifier: Apache-2.0
 */

package io.leapsight.jepsen;

/** Client could not connect — the node is unreachable. */
public class BondyNodeDownException extends RuntimeException {
  public BondyNodeDownException() {
    super();
  }
}
