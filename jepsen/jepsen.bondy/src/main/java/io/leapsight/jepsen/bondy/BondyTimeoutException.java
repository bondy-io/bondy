/*
 * SPDX-FileCopyrightText: 2016 - 2026 Leapsight
 * SPDX-License-Identifier: Apache-2.0
 */

package io.leapsight.jepsen.bondy;

/**
 * The request timed out connecting or waiting for the reply: the operation
 * may or may not have taken effect.
 */
public class BondyTimeoutException extends RuntimeException {
  public BondyTimeoutException() {
    super();
  }
}
