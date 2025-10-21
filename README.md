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

## ⚙️ 2. Instrucciones de Despliegue

### 🧩 Requisitos Previos
- Node.js ≥ 18  
- [Hardhat](https://hardhat.org/) o [Remix IDE](https://remix.ethereum.org/)  
- Cuenta con fondos de testnet (por ejemplo Sepolia o Goerli)  
- Acceso a los **Chainlink Price Feeds** de la red elegida  

### 🧱 Despliegue en Remix
1. Compilar el contrato con el compilador **Solidity 0.8.20**.
2. Seleccionar entorno de despliegue (“Injected Provider – MetaMask”).
3. Introducir los parámetros del constructor:
   ```text
   _bankCapUSDC        → Ej: 1_000_000 * 10^6   // 1 millón de USDC equivalentes
   _withdrawalCapUSDC  → Ej: 5_000 * 10^6       // 5 mil USDC por transacción
