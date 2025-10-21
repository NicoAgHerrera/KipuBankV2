// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";


/*
    * @title KipuBankV2
    * @notice Contrato inteligente que implementa un banco extendido sobre Ethereum,
    *         capaz de administrar múltiples tipos de activos (ETH y tokens ERC-20),
    *         con control de acceso administrativo, conversión de valores a USD mediante
    *         oráculos de Chainlink y normalización de decimales al estándar USDC (6).
    *
    * @dev
    * ▪ Esta versión (V2) amplía las funcionalidades del contrato original **BancoKipu**:
    *    - Se incorpora **soporte multi-token**, permitiendo depósitos y retiros tanto de ETH
    *      como de cualquier token ERC-20 aprobado por la administración.
    *    - Se añade un **sistema de control de acceso** basado en roles de OpenZeppelin
    *      (`AccessControl`), restringiendo funciones sensibles (como la asignación de oráculos)
    *      al rol administrativo (`ADMIN_ROLE`).
    *    - Se integra una **contabilidad interna en USD**, basada en los valores obtenidos
    *      de oráculos de precios de **Chainlink** (`AggregatorV3Interface`), para controlar
    *      los límites globales y por transacción en unidades equivalentes a USDC (6 decimales).
    *    - Se implementa una **conversión automática de decimales** entre los distintos tokens
    *      y el formato de USDC, normalizando el valor de todos los activos.
    *    - Se mantienen los **límites inmutables**:
    *         {i_topeBancoUSDC} → Límite global del banco expresado en USD (escala USDC).
    *         {i_topeRetiroUSDC} → Límite máximo de retiro permitido por transacción (USD).
    *    - Se utiliza `address(0)` como identificador del token nativo ETH.
    *    - Se conservan los **principios de seguridad y arquitectura del contrato original**:
    *         • Mappings anidados (`mapping(usuario => mapping(token => Balance))`)
    *           para la gestión independiente de saldos por token.
    *         • Uso de errores personalizados y eventos detallados para trazabilidad.
    *         • Patrón **checks-effects-interactions**, asegurando consistencia y
    *           evitando vulnerabilidades de reentrancia.
    *         • Variables `constant` e `immutable` para eficiencia en gas y claridad.
    *
    * ▪ Funcionalmente, el contrato:
    *    - Permite depósitos y retiros tanto en ETH como en tokens ERC-20.
    *    - Gestiona contabilidad multi-activo unificada en USD.
    *    - Aplica límites globales y por transacción en base a oráculos.
    *    - Solo el administrador puede registrar o modificar oráculos de tokens aceptados.
    *    - Emite eventos para cada operación relevante (depósito, retiro, actualización de feed).
    *
    * ▪ Arquitectura general:
    *    - Basado en `AccessControl` (OpenZeppelin).
    *    - Oráculos: `AggregatorV3Interface` (Chainlink Data Feeds).
    *    - Cumple con buenas prácticas de legibilidad, seguridad y trazabilidad.
    *
    * @version 2.0
*/
contract KipuBankV2 is AccessControl {
    /*//////////////////////////////////////////////////////////////
                               ROLES
    //////////////////////////////////////////////////////////////*/
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /*//////////////////////////////////////////////////////////////
                             DATA TYPES
    //////////////////////////////////////////////////////////////*/
    
    
    /*
    * @notice Estructura que representa la bóveda individual de un usuario por cada token.
    * @dev 
    * - Se almacena dentro del mapping anidado `s_vaults[usuario][token]`.
    * - Cada usuario puede poseer múltiples bóvedas (una por cada activo admitido: ETH o ERC-20).
    * - Contiene información básica de balance y estadísticas de operaciones realizadas.
    */
    struct Vault {
        uint256 amount;
        uint32 deposits;
        uint32 withdrawals;
    }

    /**
    * @notice Estructura que asocia un token con su oráculo de precios de Chainlink y su configuración decimal.
    * @dev 
    * - Se almacena en el mapping `s_priceFeeds[token]`.
    * - Permite obtener el valor en USD del token, considerando tanto los decimales propios del token
    *   como los decimales del feed de Chainlink.
    * - Es utilizada internamente por la función `_valueInUSDC` para normalizar los valores a la escala USDC (6).
    */
    struct PriceFeed {
        /*
        * @notice Instancia del contrato Chainlink Aggregator que provee el precio del token en USD.
        * @dev 
        * - Implementa la interfaz `AggregatorV3Interface`.
        * - Se asume que el feed retorna precios con una precisión estándar de 8 decimales (Chainlink default),
        *   aunque esto puede consultarse mediante `feed.decimals()`.
        */
        AggregatorV3Interface feed;
        /**
        * @notice Cantidad de decimales que utiliza el token asociado.
        * @dev 
        * - Permite convertir montos del token a la misma escala que el oráculo y luego a USDC (6 decimales).
        * - Se define al registrar el feed mediante la función administrativa `setPriceFeed`.
        */
        uint8 tokenDecimals;
    }

    /*//////////////////////////////////////////////////////////////
                          STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    // ---- Constants ----
        /**
        * @notice Dirección simbólica utilizada para representar el token nativo ETH.
        * @dev 
        * - En Solidity, el ETH no tiene un contrato ERC-20 asociado, por lo que se usa
        *   la dirección `address(0)` como identificador convencional para diferenciarlo.
        * - Permite mantener una estructura uniforme en el mapping `s_vaults`, de modo que
        *   todas las operaciones (depósitos, retiros, consulta de saldo) usen el mismo formato
        *   tanto para ETH como para tokens ERC-20.
        */
        address public constant ETH = address(0);
    
        /**
        * @notice Cantidad estándar de decimales utilizada por USDC.
        * @dev 
        * - USDC opera con **6 decimales**, mientras que la mayoría de tokens ERC-20 usan 18.
        * - Esta constante se emplea para normalizar los valores de todos los activos
        *   y expresar los límites globales y de retiro en una misma escala (USDC).
        */
        uint8 public constant USDC_DECIMALS = 6;

    // ---- Immutables ----
         /**
        * @notice Tope global de fondos que el banco puede custodiar, expresado en USD (escala USDC).
        * @dev 
        * - Es una variable `immutable`: se define al desplegar el contrato y no puede modificarse.
        * - El valor se almacena en unidades equivalentes a USDC (6 decimales).
        * - Cada vez que se realiza un depósito, se convierte el monto a su valor en USDC
        *   usando el oráculo de precios (`Chainlink Aggregator`), y se valida que
        *   la suma total no supere este límite.
        */
        uint256 public immutable i_bankCapUSDC; 
        
        /**
        * @notice Tope máximo permitido por transacción de retiro, expresado en USD (escala USDC).
        * @dev 
        * - También `immutable`, fijado en el constructor.
        * - Cada intento de retiro convierte el monto solicitado a su equivalente en USDC
        *   y verifica que no exceda este límite.
        */
        uint256 public immutable i_withdrawalCapUSDC; // Max withdrawal per transaction in USDC

    // ---- Mappings ----
         /*
        * @notice Estructura principal de almacenamiento de las bóvedas de los usuarios.
        * @dev 
        * - Mapping anidado: `s_vaults[usuario][token] → Vault`
        * - Permite a cada usuario mantener múltiples bóvedas, una por cada token admitido.
        * - Cada bóveda almacena el saldo actual, cantidad de depósitos y retiros.
        * - En el caso de ETH, se utiliza la clave especial `address(0)` definida como `ETH`.
        * 
        * @example
        * ```
        * s_vaults[0xUser][0xTokenA].amount → saldo en TokenA
        * s_vaults[0xUser][ETH].amount      → saldo en ETH
        * ```
        */
        mapping(address => mapping(address => Vault)) private s_vaults;

        /**
        * @notice Registro de oráculos de precios asociados a cada token.
        * @dev 
        * - Mapping: `s_priceFeeds[token] → PriceFeed`
        * - Cada token se vincula a un contrato Chainlink Aggregator y a su configuración decimal.
        * - Solo el administrador (`ADMIN_ROLE`) puede registrar o modificar estos feeds
        *   mediante la función `setPriceFeed`.
        * - El valor obtenido de cada oráculo se usa en `_valueInUSDC()` para calcular equivalencias en USD.
        */
        mapping(address => PriceFeed) private s_priceFeeds;

    // ---- Totals ----
        /**
        * @notice Suma total contable del banco expresada en unidades USDC.
        * @dev 
        * - Se actualiza en cada depósito o retiro, sumando o restando el valor del activo convertido a USD.
        * - Sirve para verificar que no se supere el límite global `{i_bankCapUSDC}`.
        * - A diferencia del V1, ya no se lleva la suma de depósitos o retiros globales, ya que
        *   la trazabilidad se maneja mediante eventos y la conversión multi-token.
        */
        uint256 private s_totalUSDC;

    /*//////////////////////////////////////////////////////////////
                               EVENTS
    //////////////////////////////////////////////////////////////*/
    
    /**
    * @notice Se emite cuando un usuario deposita fondos en su bóveda.
    * @param user Dirección del usuario que realiza el depósito.
    * @param token Dirección del token depositado (o `address(0)` si se trata de ETH).
    * @param amount Cantidad del token depositado (en sus unidades nativas, ej. wei para ETH).
    * @param newBalance Saldo actualizado de la bóveda del usuario para ese token, después del depósito.
    * @dev 
    * - Permite rastrear de forma pública todas las operaciones de ingreso de fondos.
    * - Los parámetros {user} y {token} están marcados como `indexed` para facilitar la búsqueda
    *   de todos los depósitos de un usuario o de un token específico en los logs de la blockchain.
    * - Empleado en las funciones internas de depósito (`_deposit`).
    */
    event Deposited(address indexed user, address indexed token, uint256 amount, uint256 newBalance);

    /**
    * @notice Se emite cuando un usuario realiza un retiro desde su bóveda.
    * @param user Dirección del usuario que retira los fondos.
    * @param token Dirección del token retirado (o `address(0)` si es ETH).
    * @param amount Cantidad retirada (en las unidades nativas del token).
    * @param newBalance Saldo restante en la bóveda del usuario luego del retiro.
    * @dev 
    * - Facilita el seguimiento de las operaciones de salida de fondos.
    * - Los parámetros {user} y {token} se declaran `indexed` para permitir filtrar retiros
    *   por usuario o por tipo de token en exploradores o herramientas de auditoría.
    * - Empleado en las funciones internas de retiro (`_withdraw`).
    */
    event Withdrawn(address indexed user, address indexed token, uint256 amount, uint256 newBalance);
   
   /**
    * @notice Se emite cuando se asigna o actualiza el oráculo de precios de un token.
    * @param token Dirección del token ERC-20 (o `address(0)` para ETH) al que se le configura el feed.
    * @param feed Dirección del contrato Chainlink Aggregator asociado.
    * @param decimals Número de decimales del token configurado.
    * @dev 
    * - Este evento es emitido únicamente por funciones con privilegios administrativos (`setPriceFeed`).
    * - Permite auditar qué feeds fueron registrados o modificados y con qué configuración.
    * - Los parámetros {token} y {feed} están `indexed` para facilitar la trazabilidad por activo o feed.
    */
    event FeedUpdated(address indexed token, address indexed feed, uint8 decimals);
    
    /*//////////////////////////////////////////////////////////////
                               ERRORS
    //////////////////////////////////////////////////////////////*/
    
    /**
    * @notice Error lanzado cuando se intenta ejecutar una operación con monto cero.
    * @dev 
    * - Aplica tanto para depósitos como para retiros.
    * - Evita operaciones vacías que consumirían gas innecesariamente o podrían 
    *   alterar contadores sin cambios reales en el estado.
    */
    error ZeroAmount();
    
    /**
    * @notice Error lanzado cuando un usuario intenta retirar más de su saldo disponible.
    * @param available Saldo actual disponible en la bóveda del usuario (en unidades del token correspondiente).
    * @param requested Monto solicitado para el retiro (en las mismas unidades del token).
    * @dev 
    * - Protege la integridad del sistema asegurando que no se extraigan fondos inexistentes.
    * - Se lanza dentro de la función interna `_withdraw` antes de efectuar la transferencia.
    */
    error InsufficientBalance(uint256 available, uint256 requested);
    
    /**
    * @notice Error lanzado cuando la suma total contable del banco supera el límite global permitido.
    * @param attempted Valor total (en unidades USDC) luego de intentar registrar un nuevo depósito.
    * @param cap Tope máximo global del banco (en unidades USDC) definido en el despliegue.
    * @dev 
    * - Se utiliza en la función `_deposit` para evitar que el total custodiado exceda 
    *   el límite `{i_bankCapUSDC}`.
    * - Este límite global protege la solvencia del contrato ante un exceso de fondos.
    */
    error BankCapExceeded(uint256 attempted, uint256 cap);
    
    /**
    * @notice Error lanzado cuando el valor en USD de un retiro excede el límite permitido por transacción.
    * @param requestedUSDC Valor equivalente en USDC del monto solicitado.
    * @param maxUSDC Límite máximo de retiro por transacción (en USDC) configurado en el constructor.
    * @dev 
    * - Se lanza durante la ejecución de `_withdraw`.
    * - Permite mantener un control de riesgo operativo, limitando montos excesivos 
    *   en una sola operación de retiro.
    */
    error WithdrawalCapExceeded(uint256 requestedUSDC, uint256 maxUSDC);
    
    /**
    * @notice Error lanzado cuando se intenta operar con un token que no tiene configurado su oráculo de precios.
    * @param token Dirección del token ERC-20 (o `address(0)` para ETH) sin feed registrado.
    * @dev 
    * - Aparece al intentar calcular equivalencias en USD dentro de `_valueInUSDC()`.
    * - Garantiza que solo se manejen tokens con fuentes de precios verificadas (Chainlink).
    * - Evita conversiones erróneas o manipulación de valores sin respaldo de oráculo.
    */
    error FeedNotConfigured(address token);

    /**
    * @notice Error lanzado cuando falla la transferencia nativa de ETH mediante `call`.
    * @dev 
    * - Se utiliza en la función `withdrawETH` cuando la llamada `payable(msg.sender).call{value: ...}` retorna `false`.
    * - Indica un fallo en el envío de fondos al usuario (por ejemplo, si la dirección receptora es un contrato sin fallback payable).
    * - No incluye datos de error bajos niveles, ya que el contexto es suficiente para depuración segura.
    */
    error NativeTransferFailed();

    
    /*//////////////////////////////////////////////////////////////
                           Moddifiers
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Verifica que el monto enviado sea mayor a cero.
    /// @dev Aplica tanto para depósitos de ETH como de tokens.
    modifier nonZeroAmount(uint256 _amount) {
        if (_amount == 0) revert ZeroAmount();
        _;
    }

    
    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
    * @notice Inicializa el contrato estableciendo los límites operativos del banco
    *         y configurando los roles administrativos iniciales.
    *
    * @param _bankCapUSDC        Tope global (en USDC) que el banco puede custodiar entre todos los usuarios y tokens.
    * @param _withdrawalCapUSDC  Tope máximo (en USDC) que puede retirarse en una sola transacción por cualquier usuario.
    *
    * @dev 
    * - Ambos parámetros se asignan a variables `immutable`, lo que significa que 
    *   sus valores no pueden modificarse después del despliegue.
    * - El límite global (`i_bankCapUSDC`) y el límite por retiro (`i_withdrawalCapUSDC`)
    *   están expresados en unidades USDC (6 decimales), ya que la contabilidad interna
    *   se normaliza en USD utilizando oráculos Chainlink.
    * - El despliegue también otorga al creador del contrato (`msg.sender`) los roles:
    *     • `DEFAULT_ADMIN_ROLE`: Permite administrar otros roles dentro del sistema.
    *     • `ADMIN_ROLE`: Permite configurar oráculos y otros parámetros administrativos.
    * - Este diseño sigue las prácticas recomendadas de OpenZeppelin para control de acceso
    *   basado en roles (`AccessControl`), mejorando la seguridad y escalabilidad del sistema.
    *
    */
    constructor(uint256 _bankCapUSDC, uint256 _withdrawalCapUSDC) {
        i_bankCapUSDC = _bankCapUSDC;
        i_withdrawalCapUSDC = _withdrawalCapUSDC;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                        ADMINISTRATION FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /*
    * @notice Asigna o actualiza el oráculo de precios (price feed) asociado a un token.
    *
    * @dev 
    * - Solo puede ser ejecutada por cuentas con el rol `ADMIN_ROLE`.
    * - Permite registrar una fuente oficial de precios (Chainlink Aggregator) para cada token
    *   que el banco soporte. Esto es esencial para convertir montos de distintos tokens a su
    *   valor equivalente en USD (estandarizado a 6 decimales de USDC).
    * - La información se guarda en el mapping `s_priceFeeds`, donde cada token (clave) 
    *   apunta a una estructura {PriceFeed} con:
    *     • `feed` → Dirección del contrato AggregatorV3Interface (fuente de datos Chainlink).
    *     • `tokenDecimals` → Cantidad de decimales que usa el token (por ejemplo, 18 o 6).
    * - Al actualizar un feed ya existente, simplemente se sobreescribe con el nuevo valor.
    * - Emite un evento `FeedUpdated` para permitir auditorías y seguimiento en la blockchain.
    *
    * @param _token Dirección del token ERC-20 cuyo feed se desea registrar o actualizar.
    *               Puede usarse `address(0)` para representar ETH.
    * @param _feed Dirección del contrato Chainlink AggregatorV3Interface que provee el precio.
    * @param _decimals Número de decimales que utiliza el token (por ejemplo, 18 para la mayoría
    *                  de los ERC-20 o 6 para tokens estables como USDC/USDT).
    *
    * @example
    *   // Ejemplo de configuración (solo admin):
    *   setPriceFeed(0xC02a...WETH, 0x5f4e...ETH_USD, 18);
    *   // Esto asocia el token WETH con su feed ETH/USD de Chainlink y registra que tiene 18 decimales.
    *
    * @security
    * - Solo cuentas con privilegios de administrador pueden ejecutar esta función.
    * - No se valida automáticamente si el feed es válido; se asume que el administrador
    *   ingresa fuentes oficiales de Chainlink.
    * - Un feed incorrecto podría alterar el cálculo de valor en USD, por lo tanto
    *   debe configurarse con precaución.
    */
    function setPriceFeed(address _token, address _feed, uint8 _decimals)
        external
        onlyRole(ADMIN_ROLE)
    {
        s_priceFeeds[_token] = PriceFeed(AggregatorV3Interface(_feed), _decimals);
        emit FeedUpdated(_token, _feed, _decimals);
    }

    /*//////////////////////////////////////////////////////////////
                           DEPOSIT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
    * @notice Función especial que se ejecuta automáticamente cuando el contrato recibe ETH sin datos (`data` vacío).
    * @dev Se activa en transferencias directas de ETH y redirige el valor recibido a `_deposit`.
    */
    receive() external payable nonZeroAmount(msg.value) {
        _deposit(msg.sender, ETH, msg.value);
    }

    /**
    * @notice Permite depositar ETH explícitamente mediante llamada de función.
    * @dev Equivalente a `receive`, pero ideal para interfaces y dApps.
    */
    function depositETH() external payable nonZeroAmount(msg.value) {
        _deposit(msg.sender, ETH, msg.value);
    }

    /**
    * @notice Deposita tokens ERC-20 en la bóveda personal del remitente.
    * @param _token Dirección del token ERC-20.
    * @param _amount Cantidad de tokens a transferir.
    * @dev Requiere aprobación previa (`approve`) y oráculo configurado.
    */
    function depositToken(address _token, uint256 _amount)
        external
        nonZeroAmount(_amount)
    {
        IERC20(_token).transferFrom(msg.sender, address(this), _amount);
        _deposit(msg.sender, _token, _amount);
    }

    /*//////////////////////////////////////////////////////////////
                           WITHDRAW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /*
    * @notice Permite a un usuario retirar su saldo en ETH desde su bóveda personal.
    *
    * @param _amount Cantidad de ETH a retirar (en wei).
    *
    * @dev 
    * - Llama internamente a `_withdraw()` para aplicar toda la lógica de validaciones:
    *     • Monto no nulo (`nonZeroAmount`).
    *     • Suficiencia de saldo.
    *     • Límite máximo por transacción en equivalencia USDC.
    * - Luego realiza la transferencia nativa de ETH al usuario usando `.call{value: _amount}("")`,
    *   en lugar de `.transfer` o `.send`, para evitar las restricciones de gas (2300) 
    *   e incrementar compatibilidad con contratos receptores más complejos.
    * - Si la llamada falla, lanza el error personalizado `NativeTransferFailed()`.
    * - Emite el evento `Withdrawn` desde la función `_withdraw`.
    *
    * @security
    * - Sigue el patrón *checks-effects-interactions*: primero valida, luego actualiza el estado
    *   y al final interactúa con el entorno externo (transferencia).
    * - El uso de `.call` evita reverts inesperados por consumo de gas.
    *
    * @example
    *   kipuBank.withdrawETH(1 ether);
    */
    function withdrawETH(uint256 _amount) external {
        _withdraw(msg.sender, ETH, _amount);
        (bool ok, ) = payable(msg.sender).call{value: _amount}("");
        if (!ok) revert NativeTransferFailed();
    }

    /*
    * @notice Permite a un usuario retirar tokens ERC-20 previamente depositados.
    *
    * @param _token Dirección del token ERC-20 a retirar.
    * @param _amount Cantidad de tokens a retirar (en unidades del token).
    *
    * @dev 
    * - Llama internamente a `_withdraw()` para realizar todas las validaciones
    *   (monto no nulo, saldo suficiente y control de límites en USDC).
    * - Una vez actualizado el estado, transfiere los tokens al usuario con `IERC20.transfer()`.
    *
    * @security
    * - Aplica el patrón *checks-effects-interactions*, actualizando primero el estado antes de transferir.
    *
    * @example
    *   // Ejemplo: retirar 50 DAI
    *   kipuBank.withdrawToken(address(DAI), 50 ether);
    */
    function withdrawToken(address _token, uint256 _amount) external {
        _withdraw(msg.sender, _token, _amount);
        IERC20(_token).transfer(msg.sender, _amount);
    }

    /*//////////////////////////////////////////////////////////////
                         CORE INTERNAL LOGIC
    //////////////////////////////////////////////////////////////*/

    /*
    * @notice Registra un depósito en la bóveda del usuario para un token determinado.
    *
    * @param _user Dirección del usuario que realiza el depósito.
    * @param _token Dirección del token ERC-20 depositado, o `address(0)` para ETH.
    * @param _amount Cantidad del token depositado (en sus unidades nativas, ej. wei o 10⁻¹⁸).
    *
    * @dev 
    * - Función interna llamada por los métodos públicos `depositETH`, `depositToken` o el `receive()`.
    * - Convierte el monto recibido a su valor equivalente en USDC mediante `_valueInUSDC()`.
    * - Verifica que el nuevo total contable del banco (`s_totalUSDC`) no supere el límite global `{i_bankCapUSDC}`.
    * - Si se supera el tope, lanza `BankCapExceeded(newTotal, i_bankCapUSDC)`.
    * - Si todo es válido, actualiza:
    *     • El total contable global (`s_totalUSDC`).
    *     • El saldo individual del usuario (`v.amount`).
    *     • El contador de depósitos (`v.deposits`).
    * - Finalmente, emite el evento `Deposited`.
    *
    * @security 
    * - Sigue el patrón *checks-effects-interactions*: realiza todas las validaciones antes de modificar el estado.
    *
    * @example
    *   // Ejemplo 1: depósito de 1 ETH
    *   _deposit(msg.sender, address(0), 1);
    *
    *   // Ejemplo 2: depósito de 100 DAI (18 decimales)
    *   _deposit(msg.sender, address(DAI), 100);
    */
    function _deposit(address _user, address _token, uint256 _amount) internal {
        uint256 valueUSDC = _valueInUSDC(_token, _amount);
        uint256 newTotal = s_totalUSDC + valueUSDC;
        if (newTotal > i_bankCapUSDC) revert BankCapExceeded(newTotal, i_bankCapUSDC);
        s_totalUSDC = newTotal;

        Vault storage v = s_vaults[_user][_token];
        v.amount += _amount;
        v.deposits += 1;

        emit Deposited(_user, _token, _amount, v.amount);
    }

    /**
    * @notice Retira fondos de la bóveda de un usuario para un token específico.
    * 
    * @param _user Dirección del usuario que retira.
    * @param _token Dirección del token (o `address(0)` para ETH).
    * @param _amount Cantidad a retirar (en unidades del token, no en USD).
    *
    * @dev 
    * - Verifica que el monto sea mayor a cero mediante el modifier `nonZeroAmount`.
    * - Controla que el usuario tenga saldo suficiente antes de continuar.
    * - Calcula el valor equivalente en USDC para comprobar que no exceda
    *   el límite máximo por transacción (`i_withdrawalCapUSDC`).
    * - Actualiza los saldos en storage siguiendo el patrón *checks-effects-interactions*.
    * - Emite el evento `Withdrawn` tras un retiro exitoso.
    */
    function _withdraw(address _user, address _token, uint256 _amount)
        internal
        nonZeroAmount(_amount)
    {
        Vault storage v = s_vaults[_user][_token];
        if (v.amount < _amount) revert InsufficientBalance(v.amount, _amount);

        uint256 valueUSDC = _valueInUSDC(_token, _amount);
        if (valueUSDC > i_withdrawalCapUSDC)
            revert WithdrawalCapExceeded(valueUSDC, i_withdrawalCapUSDC);

        s_totalUSDC -= valueUSDC;
        v.amount -= _amount;
        v.withdrawals += 1;

        emit Withdrawn(_user, _token, _amount, v.amount);
    }

    /*//////////////////////////////////////////////////////////////
                      CHAINLINK CONVERSION UTILITIES
    //////////////////////////////////////////////////////////////*/

    /*
    * @notice Convierte un monto de un token (o ETH) a su valor equivalente expresado en USDC.
    *
    * @param _token Dirección del token ERC-20 a convertir, o `address(0)` para ETH.
    * @param _amount Cantidad del token a convertir (en sus unidades nativas, ej. wei o 10⁻¹⁸).
    * @return Valor en unidades USDC (escala 10⁶) equivalente al monto del token ingresado.
    *
    * @dev 
    * - Usa los oráculos de precios de Chainlink (AggregatorV3Interface) para obtener el precio actual del token en USD.
    * - Combina la información de decimales tanto del token como del feed para realizar una conversión precisa.
    * - Devuelve el valor equivalente en formato USDC (6 decimales estándar).
    *
    * @workflow
    * 1. Busca en el mapping `s_priceFeeds` la configuración del token.
    * 2. Si no hay feed configurado, lanza `FeedNotConfigured(_token)`.
    * 3. Obtiene el último valor reportado (`price`) desde el oráculo Chainlink.
    * 4. Ajusta el valor combinando los decimales del token (`decToken`) y del feed (`decFeed`).
    * 5. Retorna el monto equivalente normalizado a los decimales de USDC (6).
    *
    * @example
    *   Supongamos:
    *     - Token: DAI (18 decimales)
    *     - Feed: DAI/USD = 1 * 10⁸ (8 decimales)
    *     - Monto: 100 * 10¹⁸
    *   Resultado: (100 * 10¹⁸ * 1 * 10⁸) / 10^(18+8-6) = 100 * 10⁶ (→ 100 USDC)
    *
    * @security
    * - Confía únicamente en oráculos Chainlink confiables y actualizados.
    * - La validación `require(price > 0)` evita el uso de precios corruptos o feeds sin datos.
    * - No realiza escritura en storage, por lo que es `view` y libre de efectos secundarios.
    */
    function _valueInUSDC(address _token, uint256 _amount) internal view returns (uint256) {
        PriceFeed memory info = s_priceFeeds[_token];
        if (address(info.feed) == address(0)) revert FeedNotConfigured(_token);

        (, int256 price, , , ) = info.feed.latestRoundData();
        require(price > 0, "Invalid price");

        uint8 decToken = info.tokenDecimals;
        uint8 decFeed = info.feed.decimals();

        uint256 usdValue = (_amount * uint256(price)) / (10 ** (decToken + decFeed - USDC_DECIMALS));
        return usdValue;
    }

    /*//////////////////////////////////////////////////////////////
                                VIEWS
    //////////////////////////////////////////////////////////////*/

    /**
    * @notice Devuelve los datos de la bóveda de un usuario para un token determinado.
    * @param _user Dirección del usuario.
    * @param _token Dirección del token ERC-20 (o `address(0)` para ETH).
    * @return amount Saldo actual del usuario en el token.
    * @return deposits Número de depósitos realizados.
    * @return withdrawals Número de retiros efectuados.
    * @dev Función de solo lectura que facilita la consulta externa de balances y métricas individuales.
    */
    function getVault(address _user, address _token)
        external
        view
        returns (uint256 amount, uint32 deposits, uint32 withdrawals)
    {
        Vault storage v = s_vaults[_user][_token];
        return (v.amount, v.deposits, v.withdrawals);
    }

    /**
    * @notice Devuelve el valor total custodiado por el banco expresado en equivalentes USDC.
    * @return Total global contable (`s_totalUSDC`) acumulado en el sistema.
    * @dev Permite auditar la capacidad actual frente al límite global (`i_bankCapUSDC`).
    */
    function getTotalUSDC() external view returns (uint256) {
        return s_totalUSDC;
    }

    /*
    * @notice Devuelve la configuración del oráculo de precios asociada a un token.
    *
    * @param _token Dirección del token a consultar.
    * @return feed Dirección del contrato Chainlink Aggregator asociado.
    * @return tokenDecimals Número de decimales configurados para el token.
    *
    * @dev 
    * - Permite conocer si un token tiene su feed configurado en el sistema.
    * - Si el token **no fue configurado**, devuelve `feed = address(0)` y `tokenDecimals = 0`.
    *   Esto sirve para verificar desde una interfaz (o auditoría externa) si un token está habilitado.
    * - La información proviene directamente del mapping `s_priceFeeds`.
    * - Útil para frontends, scripts de administración o validaciones previas antes de operar con un nuevo activo.
    *
    * @example
    *   // Si el feed de DAI fue configurado:
    *   getFeed(DAI) → (0xABCD...1234, 18)
    *
    *   // Si un token no fue configurado:
    *   getFeed(0x9999...) → (0x0000...0000, 0)
    */
    function getFeed(address _token) external view returns (address, uint8) {
        PriceFeed storage f = s_priceFeeds[_token];
        return (address(f.feed), f.tokenDecimals);
    }
}



