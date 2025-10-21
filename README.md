# 🏦 KipuBank V2 — Banco Inteligente Multi-Token en Solidity

### 📘 Descripción General

**KipuBankV2** es una versión extendida del contrato `BancoKipu` desarrollado en la etapa anterior.  
El objetivo principal de esta nueva versión es **evolucionar de un banco uniactivo (solo ETH)**  
a un **sistema multi-activo**, capaz de administrar simultáneamente **ETH y múltiples tokens ERC-20**  
manteniendo **contabilidad unificada en USD** mediante oráculos **Chainlink**.

Este contrato implementa además **control de acceso basado en roles**, una **arquitectura modular y segura**,  
y aplica **patrones de buenas prácticas** ampliamente aceptados (checks-effects-interactions, errores personalizados,  
uso de `immutable` y `constant`, eventos detallados, entre otros).

---

## 🚀 1. Mejoras Introducidas y Motivación

### 🔹 1.1 Soporte Multi-Token
- **Antes (V1):** solo se admitían depósitos y retiros en ETH.  
- **Ahora (V2):** se incorpora soporte para cualquier token ERC-20 aprobado por la administración.  
  Cada usuario puede tener múltiples bóvedas (una por token), lo que amplía el alcance operativo del sistema.  
- **Motivo:** mejorar la escalabilidad del banco y permitir una gestión diversificada de activos digitales.

### 🔹 1.2 Control de Acceso Administrativo (OpenZeppelin AccessControl)
- Se implementa un sistema de **roles**:
  - `DEFAULT_ADMIN_ROLE`: control total del sistema y delegación de permisos.
  - `ADMIN_ROLE`: puede registrar y actualizar oráculos de precios o límites operativos.
- **Motivo:** restringir funciones sensibles (por ejemplo, la configuración de feeds) a personal autorizado.  
  Mejora la seguridad y el cumplimiento de buenas prácticas de gestión.

### 🔹 1.3 Contabilidad Interna en USD
- Se introduce la conversión de todos los valores a **USDC (6 decimales)** usando **Chainlink Data Feeds**.  
- Esto permite medir los límites del banco (`i_bankCapUSDC`) y de retiro (`i_withdrawalCapUSDC`)  
  en una misma unidad estable y confiable.  
- **Motivo:** facilitar auditorías y mantener coherencia entre activos de distinto valor o volatilidad.

### 🔹 1.4 Integración de Oráculos Chainlink
- Cada token aprobado se asocia a un **feed de precios** de Chainlink (`AggregatorV3Interface`).  
- El contrato obtiene el valor actual en USD de cada activo en tiempo real.  
- **Motivo:** garantizar precisión y transparencia en la valoración de los activos, evitando precios manipulables.

### 🔹 1.5 Conversión Automática de Decimales
- Dado que los tokens ERC-20 usan diferentes cantidades de decimales (6, 8, 18…),  
  el contrato convierte todos los valores a una escala uniforme (USDC = 6).  
- **Motivo:** evitar errores de cálculo y simplificar la comparación entre activos.

### 🔹 1.6 Mappings Anidados y Contabilidad Multi-Usuario
- Se implementa `mapping(address => mapping(address => Vault))`  
  que permite manejar múltiples bóvedas (una por token) por usuario.  
- **Motivo:** extender la funcionalidad del V1 manteniendo un almacenamiento eficiente.

### 🔹 1.7 Seguridad y Buenas Prácticas
- Uso del patrón **Checks-Effects-Interactions** para prevenir ataques de reentrancia.  
- Variables `constant` e `immutable` para optimización de gas.  
- Errores personalizados (`error`) para reducir costo de revert y mejorar la trazabilidad.  
- Eventos detallados (`Deposited`, `Withdrawn`, `FeedUpdated`) para auditoría.  

---

## ⚙️ 2. Despliegue

### 🧩 Requisitos Previos
- [Remix IDE](https://remix.ethereum.org/) o entorno Hardhat.  
- MetaMask configurado en **Sepolia** (u otra testnet compatible).  
- Fondos de testnet ETH (para gas).  
- Direcciones de oráculos Chainlink disponibles en la red elegida.

---

### 🧱 Proceso de Despliegue (Remix)
1. Abrir [Remix](https://remix.ethereum.org/) y crear el archivo `contracts/KipuBankV2.sol`.  
2. Compilar con **Solidity 0.8.30** (license MIT, optimization **enabled**, 200 runs).  
3. Conectar MetaMask a **Sepolia**.  
4. En la pestaña **Deploy & Run**, seleccionar el contrato `KipuBankV2`.  
5. Ingresar los parámetros del constructor:  
   - `_bankCapUSDC`: tope global del banco en USD (ej. `1000000 * 10**6`)  
   - `_withdrawalCapUSDC`: tope máximo por retiro (ej. `10000 * 10**6`)  
6. Presionar **Deploy** y confirmar la transacción en MetaMask.  
7. Guardar la dirección del contrato desplegado.

---

### 🔍 Verificación en Etherscan
1. Copiar la dirección del contrato.  
2. Ir a [Sepolia Etherscan → Verify & Publish](https://sepolia.etherscan.io/verifyContract).  
3. Seleccionar:
   - Compilador: `Solidity 0.8.20+commit.a1b79de6`
   - Optimization: **Yes/No**
   - Runs: `200`
   - License: `MIT`
   - Contract Name: `KipuBankV2`
4. Pegar el **flatten completo** del contrato (`KipuBankV2.sol`).  
5. Confirmar.  
Una vez verificado, las funciones estarán disponibles desde el explorador.

---

## 🧭 3. Interacción

### 💰 Depósitos
| Operación | Descripción | Método |
|------------|--------------|--------|
| Depositar ETH | Enviar ETH directamente al contrato o usar `depositETH()` | `receive()` o `depositETH()` |
| Depositar token ERC-20 | Transferir tokens aprobados al banco | `depositToken(address token, uint256 amount)` |

> 🔸 Antes de usar `depositToken`, el usuario debe hacer `approve(contract, amount)` desde el token correspondiente.

---

### 💸 Retiros
| Operación | Descripción | Método |
|------------|-------------|--------|
| Retirar ETH | Extrae fondos en ETH del usuario | `withdrawETH(uint256 amount)` |
| Retirar token ERC-20 | Extrae tokens específicos de la bóveda | `withdrawToken(address token, uint256 amount)` |

---

### 🔎 Consultas
| Función | Descripción |
|----------|-------------|
| `getVault(address user, address token)` | Devuelve saldo, depósitos y retiros de un usuario para un token. |
| `getTotalUSDC()` | Retorna el valor total custodiado por el banco en USD equivalentes. |
| `getFeed(address token)` | Informa el oráculo y decimales asociados al token. |

---

### ⚙️ Funciones Administrativas (solo `ADMIN_ROLE`)
| Función | Descripción |
|----------|-------------|
| `setPriceFeed(address token, address feed, uint8 decimals)` | Registra o actualiza el oráculo de precios de un token. |

---

## 🧩 4. Notas de Diseño y Trade-Offs

### 🔸 Estandarización de Valor
Se optó por una **contabilidad interna en USD (escala USDC)** para evitar volatilidad y mantener coherencia entre activos de distinto tipo.  
Esto implica una dependencia de **oráculos Chainlink**, pero garantiza transparencia y consistencia en auditorías.

### 🔸 Seguridad por Roles
El uso de `AccessControl` introduce complejidad, pero ofrece escalabilidad y control granular sobre permisos administrativos.  
Permite delegar autoridad sin comprometer la seguridad del sistema.

### 🔸 Manejo de ETH y Tokens Unificado
Se usa `address(0)` para representar ETH, lo que simplifica la estructura y evita duplicar lógica de depósito/retiro.

### 🔸 Conversión de Decimales
Normalizar a 6 decimales agrega un paso de cómputo, pero estandariza todos los tokens frente al USD y evita errores de redondeo.

### 🔸 Patrón de Seguridad
El patrón *checks-effects-interactions* incrementa la claridad del código y evita ataques de reentrancia.  
Se priorizó seguridad sobre micro-optimización de gas.

### 🔸 Tope Global Expresado en USD (USDC)

El **límite global del banco (`i_bankCapUSDC`)** se define en dólares (escala USDC),  
por lo que todas las operaciones deben convertirse desde ETH o tokens a su valor equivalente en USD utilizando los **oráculos de Chainlink**.  
Esto introduce ciertos efectos prácticos:

- El usuario **debe conocer el precio actual del activo** (por ejemplo, ETH/USD) para estimar cuánto puede depositar sin superar el límite.  
- El **tope efectivo en ETH cambia dinámicamente** según la cotización: si el precio sube, el banco acepta menos ETH; si baja, acepta más.  
- En entornos sin interfaz (como Remix), este comportamiento puede resultar confuso, ya que el usuario no ve el valor convertido automáticamente.

> 💡 Este diseño replica el comportamiento de un sistema bancario real donde los límites operativos se expresan en una moneda estable (USD), priorizando coherencia contable y estabilidad por sobre la simplicidad de uso.

---

### 🔸 Redondeo y Pérdida de Precisión en Depósitos Pequeños

Dado que la contabilidad global (`s_totalUSDC`) se maneja con **enteros normalizados a 6 decimales (escala USDC)**,  
los depósitos extremadamente pequeños pueden **redondearse hacia cero** al convertirse desde ETH o tokens debido a la división entera en Solidity:

```solidity
valueUSDC = (_amount * price * 10**USDC_DECIMALS) / (10**(decToken + decFeed));
