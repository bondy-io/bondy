/*
 * SPDX-FileCopyrightText: 2016 - 2026 Leapsight
 * SPDX-License-Identifier: Apache-2.0
 */

package io.leapsight.jepsen.bondy;

/**
 * The connection was refused: the request never reached a server, so the
 * operation provably did not happen.
 */
public class BondyNodeDownException extends RuntimeException {
  public BondyNodeDownException() {
    super();
  }
}
